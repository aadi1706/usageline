# Usageline: design decisions explained

Each section says what the decision is, why it was made here, what its limits are, and gives three interview questions. The limits are included on purpose: knowing where a design falls short is what interviewers usually probe.

---

## 1. Multi-tenancy

**What it is.** One running app and one database serve many customers ("tenants"). Each tenant's data must stay separate from the others'.

**What we did.** Every tenant-owned row (`usage_events`, `invoices`) has a `tenant_id` column, and every query filters on it. All tenants share the same tables. This is called the *shared schema* (or "pool") model. The alternatives are a separate schema per tenant, or a separate database per tenant.

**Why.** It is the simplest option and the cheapest to run: one migration updates everyone, and one connection pool serves all. Per-tenant databases give stronger isolation but cost far more to operate. Billing platforms usually have a huge number of small tenants, which favours the shared model.

**Limits (be upfront about these).**
- Isolation depends on every query remembering the `tenant_id` filter. One forgotten filter leaks data. A test covers it (`test_invoice_only_counts_own_tenant_usage`), but nothing enforces it in the database itself.
- There is no authentication yet. Anyone who can call the API can name any tenant ID. Real multi-tenancy needs auth that ties a caller to one tenant.
- A "noisy neighbour" tenant sending lots of events can slow everyone else down. There is no per-tenant rate limiting.

**Interview questions**
1. What are the main ways to do multi-tenancy in a database, and what are the trade-offs between them?
2. How would you make sure one tenant can never read another tenant's rows, even if a developer forgets a filter? (Hint: look up PostgreSQL row-level security.)
3. How would you stop one tenant from degrading service for the others?

---

## 2. Money as integer cents

**What it is.** Prices and totals are stored as whole numbers of cents (`1250`, not `12.50`).

**Why.** Computers store decimals like 0.1 in binary floating point, which cannot represent them exactly. `0.1 + 0.2` gives `0.30000000000000004` in Python. Tiny errors like that add up across many invoices, and billing has to be exact. Integers are exact, fast, and fine to add and multiply.

**Alternatives.** A decimal type (`NUMERIC` in Postgres, `Decimal` in Python) is also correct and is common. Integer minor units are what Stripe-style APIs use, and they avoid any rounding questions as long as prices are whole cents.

**Limits.** Our unit price is whole cents, so a price like "0.4 cents per API call" cannot be expressed. Real usage-based pricing often needs fractions of a cent. We would then store prices as `NUMERIC` and round once, at the invoice total. There is also no currency column, so everything is implicitly one currency.

**Interview questions**
1. Why is storing money in a float a bug? Show a concrete example.
2. Integer cents vs `NUMERIC`/`Decimal`: when would you choose each?
3. How would you support a price of 0.4 cents per unit, and where would you round?

---

## 3. Half-open usage periods: `[start, end)`

**What it is.** An invoice for a period counts events where `timestamp >= period_start AND timestamp < period_end`. The start is included and the end is excluded.

**Why.** Consider billing January then February. January ends at `2026-02-01T00:00:00` and February starts at that same instant. If both ends were inclusive, an event at exactly that instant would be billed twice. If both were exclusive, it would be billed zero times. With a half-open interval, every instant belongs to exactly one period, so consecutive periods tile the timeline with no gaps and no overlaps. A test pins this down (`test_invoice_period_is_start_inclusive_end_exclusive`). Programming languages use the same convention (`range(0, 5)`, list slices).

**Related choices.** Timestamps are normalised to UTC so "midnight" means the same moment for everyone. Time zones are a classic source of billing bugs.

**Limits.** Nothing stops you generating two invoices for the same tenant and overlapping periods, so a tenant could be billed twice for the same usage. A real system would add a uniqueness or overlap constraint (Postgres supports exclusion constraints on ranges). Late-arriving events (an event for January that arrives in February) are also not handled.

**Interview questions**
1. Why use a half-open interval rather than closed on both ends for billing periods?
2. What happens if an event arrives after its period's invoice was already generated? How would you handle it?
3. How would you prevent double-billing the same period in the database?

---

## 4. Alembic migrations

**What it is.** A migration is a versioned script that changes the database schema (create a table, add a column). Alembic is the migration tool for SQLAlchemy. Migrations live in `migrations/versions/`, and each has a revision ID and a `down_revision` pointing to the one before it, forming a chain. The database records its current revision in an `alembic_version` table.

**Why.** Without migrations, schema changes are manual SQL that someone must remember to run on every environment (laptop, CI, production), in the right order. Migrations make the schema reproducible, reviewable in git, and applicable the same way everywhere. `alembic upgrade head` brings any database up to date, whether it is empty or one version behind.

**Why not `Base.metadata.create_all()`?** It only creates tables that don't exist. It never alters existing ones, so it cannot evolve a live database. (We do use `create_all` in the tests, where the database is throwaway.)

**Choices to know about.** We wrote the first migration by hand rather than auto-generating it, which avoided needing a database during development. Each migration has a `downgrade()` so a change can be reversed. Be honest in interviews that downgrades are hard to make safe once data exists.

**Interview questions**
1. What problem do migrations solve, and why not just edit tables by hand?
2. How would you add a `NOT NULL` column to a table with millions of rows without downtime?
3. Two developers each create a migration from the same parent revision. What happens, and how do you fix it?

---

## 5. Multi-stage, non-root Dockerfile

**What it is.** The Dockerfile has two stages:
1. `builder` creates a virtual environment and runs `pip install`.
2. `runtime` starts from a fresh slim image and copies in only the finished virtualenv and our code.

The runtime stage then creates an unprivileged user (`app`, UID 10001) and switches to it with `USER app`.

**Why multi-stage.** Anything installed during a build (compilers, pip caches, build tools) stays in that stage's layers. Only what you explicitly `COPY --from=builder` reaches the final image, so the final image is smaller and has less in it to attack. Here `psycopg2-binary` ships prebuilt, so we don't need compilers anyway; the pattern is still the right habit, and it matters more as dependencies grow. I did not measure image sizes, so don't claim a specific saving.

**Why non-root.** By default, processes in containers run as root. If an attacker breaks into the app, root inside the container makes escaping or damaging things much easier. Running as an unprivileged user limits the damage. Kubernetes can also enforce this (`runAsNonRoot`), and many clusters reject images that run as root, so this prepares us for the Kubernetes work.

**Other details.** `requirements.txt` is copied before the code so Docker's layer cache skips reinstalling dependencies when only code changes. `.dockerignore` keeps `.git`, `.venv` and tests out of the build context. `PYTHONUNBUFFERED=1` makes logs appear immediately.

**Limits.** Dependencies are version ranges, not locked, so two builds on different days could get different versions. A lock file with hashes would make builds reproducible. We also don't scan the image for vulnerabilities yet.

**Interview questions**
1. What is a multi-stage build and what does it buy you?
2. Why shouldn't containers run as root, and how do you enforce it in Kubernetes?
3. Why does the order of `COPY` and `RUN` lines in a Dockerfile affect build speed?

---

## 6. The `/health` endpoint

**What it is.** `GET /health` returns `{"status": "ok"}` with HTTP 200. Anything that wants to know "is this process alive?" can call it: you, a load balancer, Docker, or later Kubernetes.

**Why.** Orchestrators need a cheap, standard way to decide whether to send traffic to an instance or restart it. Kubernetes uses *probes* for exactly this, and `/health` is what they will call.

**An important limit.** Ours is a *liveness* check only: it proves the web server responds, not that the database is reachable. That is deliberate for now (a database blip should not make Kubernetes restart every API pod), but a real service usually has a second *readiness* check ("am I able to serve requests right now?") that does verify the database. That second endpoint is a likely next step when we write the Helm chart.

**Interview questions**
1. What is the difference between a liveness probe and a readiness probe in Kubernetes?
2. Should a health check hit the database? What can go wrong either way?
3. What happens to traffic when a readiness probe fails? What happens when a liveness probe fails?

---

## 7. Running migrations on container start

**What it is.** The container's start command is `alembic upgrade head && exec uvicorn ...`. Each time the API container starts, it first brings the database schema up to date, then starts the server. `exec` makes uvicorn the main process so it receives stop signals correctly. Docker Compose also waits for the database's healthcheck (`pg_isready`) to pass before starting the API, so migrations don't run against a database that is not ready.

**Why.** For local development it means `docker compose up` just works on a blank machine, with no manual setup step. It is simple, and it is a common pattern for small projects.

**Limits (a favourite interview topic).** It does not scale well to production:
- With several replicas starting at once, they all try to migrate at the same time. Alembic does not lock for you on every database, so this can race.
- If a migration fails, the app container crashes. That is arguably a good thing, but it is mixed together with the app's lifecycle.
- The app's database user needs permission to alter schemas, which is more privilege than a running app should have.

The usual production fix is to run migrations as a separate one-off step: a Kubernetes `Job`, or a Helm pre-install/pre-upgrade hook. That is what we plan to do when we move to Kubernetes.

**Interview questions**
1. Why might running migrations at app startup be a problem with multiple replicas?
2. How would you run migrations in a Kubernetes deployment instead?
3. What does `depends_on` with `condition: service_healthy` do, and why isn't plain `depends_on` enough?

---

## 8. SQLite for tests

**What it is.** By default the test suite runs against an in-memory SQLite database that is created fresh for each test, so tests run in a fraction of a second with no setup. Setting `TEST_DATABASE_URL` points the same tests at Postgres instead. The tests override the app's `get_db` dependency (FastAPI's dependency injection) so the app uses the test database.

**Why.** Fast, free and self-contained tests that anyone can run with only Python installed, matching our "everything runs locally for free" rule. In CI this also means no database service is needed.

**Limits (this is the honest part).** SQLite and Postgres are different databases. SQLite is lenient about types, has no real timezone-aware timestamp type, and handles concurrency and constraints differently. A test can pass on SQLite and the same code could fail on Postgres. We reduce this risk three ways: the `TEST_DATABASE_URL` switch, the end-to-end check we did against real Postgres through Docker Compose, and by keeping queries simple. A stronger setup would run the test suite against a real Postgres container in CI (for example a GitHub Actions service container), which is a sensible next step. Note that the Alembic migration itself is not exercised by the SQLite tests, since they build tables from the models; only the Compose run exercises it.

**Interview questions**
1. What are the pros and cons of testing against SQLite when production uses Postgres?
2. What is dependency injection in FastAPI, and how did it let the tests swap the database?
3. How would you set up CI so tests run against a real Postgres?

---

# Phase 2: Continuous integration (GitHub Actions)

CI means a machine automatically checks every change you push. Our workflow is `.github/workflows/ci.yml` and has three independent jobs that run in parallel.

## 9. Linting with ruff

**What it is.** A linter reads code without running it and flags likely bugs and style problems. Ruff is a very fast Python linter and formatter. The job runs `ruff check` (lint rules) and `ruff format --check` (fails if a file isn't formatted; it does not rewrite files in CI). Rules are in `ruff.toml`: pycodestyle (`E`), pyflakes (`F`), import sorting (`I`), bugbear (`B`) and pyupgrade (`UP`).

**Why.** It catches mistakes before review and ends style arguments, since the tool decides. The first run found a real finding: `raise HTTPException(...)` inside an `except` block should say `from None`, otherwise the traceback shows a confusing chained error. We fixed it.

**A decision worth explaining.** Bugbear rule `B008` objects to function calls in default arguments, but `db: Session = Depends(get_db)` is how FastAPI is designed to be used. Rather than disable the rule everywhere, we told ruff that `fastapi.Depends` is safe (`extend-immutable-calls`). Prefer a narrow exception over turning a rule off.

**Limits.** Linting does not prove the code works, and we haven't added type checking (mypy/pyright) or security scanning.

**Interview questions**
1. What is the difference between a linter, a formatter and a type checker?
2. When is it right to suppress a lint rule, and how do you scope the suppression narrowly?
3. Why does CI run `format --check` instead of reformatting files automatically?

## 10. Tests against a real Postgres service container

**What it is.** GitHub starts a fresh `postgres:16-alpine` container next to the job (a *service container*), waits until its health check passes, then the job installs dependencies, runs `alembic upgrade head`, and runs pytest with `TEST_DATABASE_URL` pointing at it.

**Why.** This fixes the weakness we noted for SQLite tests: now CI runs the same engine as production. It also tests the migrations, which the SQLite tests never touched.

**The subtle part.** Running `alembic upgrade head` is not enough if the tests then call `create_all()`, because the test code would quietly build its own tables and the migration could be broken without anyone noticing. So the test fixture was changed: on SQLite it still builds tables from the models, but on Postgres it uses the migrated schema as-is and just empties the tables between tests (`TRUNCATE ... RESTART IDENTITY CASCADE`). Now a broken migration makes the suite fail. I ran this against a throwaway database in the local compose Postgres first to confirm it passed before pushing.

**Details.** The service health check (`pg_isready`) stops tests starting before the database accepts connections. Credentials in the workflow are throwaway values for a container that exists only for the job, so they are not secrets.

**Limits.** We test that migrations apply to an *empty* database. We don't test upgrading a database that already has data, or a downgrade. Nothing checks that the models and the migration agree (a column added to the model but forgotten in a migration would pass on SQLite and fail on Postgres, but could slip through if no test touched it); Alembic's `check` command could be added for that. We also test only one Postgres version and one Python version (3.12, matching the Dockerfile).

**Interview questions**
1. Why run tests against real Postgres in CI when SQLite is faster?
2. How does your CI make sure the migrations themselves are correct, not just the application code?
3. What is a service container, and why do you need a health check on it?

## 11. Docker build in CI (no push)

**What it is.** The third job builds the image with Docker Buildx and `push: false`. Nothing is published anywhere.

**Why.** It proves the Dockerfile still builds on a clean machine on every change. A broken Dockerfile is caught before you try to deploy. Not pushing keeps it free and avoids needing registry credentials, in line with our "everything runs for free" rule.

**Caching.** Docker layers are cached in GitHub's cache (`type=gha`), so unchanged layers (like the dependency install) are reused on later runs.

**Limits.** A successful build doesn't prove the container *runs*. We don't start it in CI or call `/health`. We also don't scan the image for vulnerabilities or publish it, and a published image would be the next step before deploying to Kubernetes.

**Interview questions**
1. What does a CI Docker build verify, and what can it not verify?
2. How do Docker layer caching and the order of Dockerfile instructions affect CI time?
3. When would you push the image from CI, and how would you tag it?

## 12. Workflow design choices

- **Triggers:** every push to `main` and every pull request targeting `main`. Pull requests run CI before merging; pushes to `main` re-verify after merging.
- **Parallel jobs:** lint, test and docker don't depend on each other, so they run at the same time and feedback is faster. A failure in one doesn't hide failures in the others.
- **pip caching:** `actions/setup-python` with `cache: pip` saves downloaded packages keyed on a hash of `requirements-dev.txt`. A change to that file invalidates the cache; otherwise later runs skip re-downloading. The first run can only save the cache, not reuse it. I did not measure the time saved, so I'm not claiming a number.
- **Least privilege:** `permissions: contents: read` gives the workflow's token only read access, so a compromised step can't push code.
- **Concurrency:** if you push twice quickly, the older run is cancelled, saving minutes.
- **Version tags:** actions are pinned to major tags (`@v4`). Pinning to a full commit SHA is safer against supply-chain attacks, but harder to maintain; that is a trade-off, not an oversight.
- **Badge:** the README shows the latest status of the workflow on `main`, so visitors see at a glance that the build is healthy.

**Interview questions**
1. Why set `permissions: contents: read` on a workflow, and what is the risk of the default?
2. What is the difference between pinning an action to `@v4` and pinning to a commit SHA?
3. Why run the three jobs in parallel instead of one after another, and when would you make one job depend on another with `needs`?
