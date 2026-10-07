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

---

# Phase 3: Kubernetes and Helm (local, with kind)

Kubernetes (K8s) is a system that runs containers for you and keeps them in the state you declared. You write YAML describing what you want ("2 copies of this container, healthy"), and K8s continuously works to make reality match. Helm is a package manager for K8s: it turns YAML templates plus a `values.yaml` file into the final manifests. kind ("Kubernetes in Docker") runs a real cluster inside a Docker container, so it is free and local.

## 13. Readiness vs liveness: `/ready` next to `/health`

**What it is.** `/health` (liveness) says "the process is alive". `/ready` (readiness) runs `SELECT 1` against the database and returns 503 if that fails. Kubernetes uses them differently:
- A failing **liveness** probe makes K8s *restart* the container.
- A failing **readiness** probe makes K8s *stop sending traffic* to that pod (it is removed from the Service) but leaves it running.

**Why two.** If the database has a short outage and we only had one check that touched the DB, K8s would restart every API pod for a problem that restarting cannot fix. Keeping liveness DB-free avoids that, while readiness protects users from being routed to pods that cannot do their job. Tests cover both: `/ready` returns 200 normally and 503 when the DB session raises, and `/health` stays 200 even then.

**Limits.** `/ready` checks only the database. It does not check that migrations have run (the migration Job handles that ordering), and a slow DB could make the probe time out, which also marks the pod not-ready.

**Interview questions**
1. What happens to a pod when its readiness probe fails vs its liveness probe?
2. Why shouldn't a liveness probe depend on a database?
3. What are startup probes for, and when would you add one?

## 14. kind and the host port mapping

**What it is.** `kind/cluster.yaml` defines a one-node cluster. `extraPortMappings` forwards host port 8081 (bound to 127.0.0.1 only) to port 30080 on the node. The Service is of type `NodePort` with `nodePort: 30080`, so traffic goes: `localhost:8081` -> kind node:30080 -> Service -> a ready API pod.

**Why.** We needed a way to reach the app from the laptop without an Ingress controller (more moving parts). NodePort plus a port mapping is the simplest working path. The port was chosen because 8000, 6333, 8001 and 5433 were already in use. The scripts target the cluster by name (`--name usageline`, `--context kind-usageline`), so they cannot touch other clusters or any existing Docker containers.

**Limits.** NodePort is a dev convenience. A real cluster would use a LoadBalancer Service or an Ingress with TLS. Binding to 127.0.0.1 means other machines cannot reach it, which is intended here. The node port in `values.yaml` and the kind file must be kept in sync by hand.

**Interview questions**
1. What are the Service types (ClusterIP, NodePort, LoadBalancer) and when do you use each?
2. How does traffic get from a browser to a pod in this setup?
3. What does an Ingress add that a plain Service does not?

## 15. The Helm chart and `values.yaml`

**What it is.** `helm/usageline/` contains templates (Deployment, Service, ConfigMap, Secret, HPA, Postgres StatefulSet, migration Job) and `values.yaml` holding every setting: image, replica count, resources, probes, security context, HPA bounds, DB settings, and so on. Defaults live in one place, and anyone can override them with `--set` or their own values file without editing templates.

**Choices to explain.**
- **ConfigMap vs Secret.** Non-secret settings (host, port, DB name, user) go in a ConfigMap; the password goes in a Secret. The DB URL is assembled inside the container from those pieces using Kubernetes `$(VAR)` substitution, so the password is never baked into the image or the ConfigMap. `existingSecret` lets you point at a Secret managed elsewhere.
- **Checksum annotations.** The Deployment template stores a hash of the config and secret. When they change, the hash changes, so pods are replaced and pick up the new values. Without it, `helm upgrade` would update the ConfigMap but running pods would keep old env vars.
- **Labels.** Standard `app.kubernetes.io/*` labels let selectors and tools find the right pods.

**Limits.** Kubernetes Secrets are only base64-encoded, not encrypted, unless the cluster enables encryption at rest. The default password in `values.yaml` is a dev placeholder. For anything real you would use an external secret manager. The password is placed in a URL, so it must be URL-safe (no `@`, `/`, `:`).

**Interview questions**
1. What does Helm give you over plain `kubectl apply -f` with YAML files?
2. Why are Kubernetes Secrets not truly secret by default, and how do you improve on that?
3. If you change a ConfigMap, do running pods see it? How do you make them restart?

## 16. Deployment: replicas, probes, resources and security

**What it is.** The API runs as a Deployment with 2 replicas. Each pod has:
- a liveness probe on `/health` and a readiness probe on `/ready`;
- resource **requests** (what the scheduler reserves: 100m CPU, 128Mi memory) and **limits** (the ceiling: 500m CPU, 256Mi memory);
- `runAsNonRoot` with `runAsUser: 10001`, `readOnlyRootFilesystem: true`, all Linux capabilities dropped, privilege escalation disabled, and the default seccomp profile.

**Why.**
- Two replicas mean one pod can die or be updated while the other keeps serving (rolling updates need this).
- Requests drive scheduling *and* autoscaling (CPU% is measured against the request). Limits stop one pod from starving others. A pod exceeding its memory limit is killed (OOMKilled); exceeding its CPU limit just gets throttled.
- A numeric `runAsUser` matters: our Dockerfile has `USER app` (a name), and Kubernetes cannot prove a *named* user is non-root, so `runAsNonRoot` would reject the pod. Setting the UID 10001 explicitly resolves that.
- The app doesn't write to disk, so a read-only root filesystem works (I confirmed the pods run and accept writes to the database). A small `emptyDir` is mounted at `/tmp` in case a library needs scratch space. If the app needed to write files, we would mount a volume rather than loosen the setting.
- The Deployment overrides the container command to run only `uvicorn`. The Dockerfile's default command runs migrations first (good for Compose), but on Kubernetes migrations belong in the Job (see 18).

**Limits.** The resource numbers are reasonable starting guesses, not measured. They should be tuned from real load data, which I have not collected. The dev Postgres container is not hardened the same way: the official image starts as root to prepare its data directory.

**Interview questions**
1. What is the difference between resource requests and limits, and what happens when each is exceeded?
2. Why does `runAsNonRoot: true` fail with a Dockerfile that has `USER app`?
3. What does `readOnlyRootFilesystem` protect against, and what do you do when an app needs to write files?

## 17. Dev Postgres as a StatefulSet with a PVC

**What it is.** A StatefulSet (not a Deployment) runs one Postgres pod. A `volumeClaimTemplate` creates a PersistentVolumeClaim (PVC), a request for 1Gi of disk that outlives any single pod. The headless Service (`clusterIP: None`) gives it a stable DNS name. In kind, a "standard" storage class provisions the volume automatically. `PGDATA` is set to a subdirectory because a freshly mounted volume can contain a `lost+found` directory that makes Postgres refuse to start in the mount root.

**Why StatefulSet.** Databases need a stable identity and storage that stays attached to them. A Deployment pod is interchangeable and its storage is disposable. If the Postgres pod is deleted, the StatefulSet recreates it and re-attaches the same PVC, so data survives.

**Limits (important).** This is for development only. One replica means no high availability, no backups, no replication, no tuning. In production you would use a managed database (RDS, Cloud SQL) or an operator. The PVC lives on the kind node's disk, so deleting the cluster deletes the data.

**Interview questions**
1. When would you use a StatefulSet instead of a Deployment?
2. What happens to a PVC when its pod is deleted? When the StatefulSet is deleted?
3. Why is running your production database inside Kubernetes a debated decision?

## 18. Migrations as a Helm hook Job

**What it is.** The migration is a Kubernetes Job annotated as a Helm hook (`pre-install,pre-upgrade`). Helm runs the Job *before* it creates or updates the Deployment and waits for it to succeed; if it fails, the release fails and the old version keeps running. The Job is deleted after success (`hook-succeeded`).

**Why.** This is the fix for the problem noted in section 7: with several replicas starting at once, running migrations at app start can race. A single Job runs them exactly once, before any new pod starts, and the app pods get a minimal-privilege start command.

**What went wrong, and what it taught (real, from this build).**
1. **Hook ordering problem.** Pre-install hooks run *before* the normal resources exist. A fresh install has no ConfigMap, Secret or database yet, so the Job would have nothing to read and nowhere to connect. Fix: the ConfigMap and Secret are also hooks (`pre-install,pre-upgrade`, weight -10) so they exist first, and the dev Postgres is a `pre-install` hook (weight -5) so it exists before the Job on a fresh install. I chose `pre-install` only for Postgres on purpose, because a `pre-upgrade` hook is deleted and recreated on every upgrade, which would restart the database each time. I verified both a fresh install and an upgrade: the upgrade completed and the Postgres pod was not restarted.
2. **Trade-off of that fix.** Hook resources are not tracked as part of the release, so `helm uninstall` does not delete the dev Postgres or its PVC, and changes to the Postgres template do not apply on upgrade. Acceptable for a dev database; it would be wrong for anything real, where the database is external anyway.
3. **A bug found in testing.** My first run hung for the full 5-minute timeout because the wait-for-database init container reported `no attempt`. Cause: it runs as UID 10001, which has no entry in the Postgres image's `/etc/passwd`, so `pg_isready` could not work out a username and refused to try. Passing `-U` explicitly fixed it. I diagnosed it by running the command by hand inside the stuck container rather than guessing.
4. **Init container.** The Job waits for the database (`pg_isready` loop) because the Postgres pod may still be starting when the Job begins.

**Limits.** Rolling back the app does not roll back migrations. Migrations must be backward-compatible with the previous app version (add columns before using them, remove them a release later), because old and new pods overlap during a rolling update.

**Interview questions**
1. Why does a `pre-install` hook sometimes fail because a ConfigMap or Secret it needs does not exist yet?
2. What are the pros and cons of migration Jobs vs init containers vs running migrations at app start?
3. Why must database migrations be backward-compatible during a rolling update?

## 19. metrics-server and the HorizontalPodAutoscaler

**What it is.** metrics-server collects CPU and memory usage from each node's kubelet and exposes it through the Kubernetes API (this is what `kubectl top` reads). The HPA reads those numbers and adjusts the Deployment's replica count between 2 and 5 to keep average CPU near 70% of the pods' *requests*.

**Why the extra flag.** kind's kubelet uses a self-signed certificate, so metrics-server cannot verify it and would never become ready. The install script adds `--kubelet-insecure-tls`. That is acceptable on a throwaway local cluster and **should not be used in production**, where you would configure proper kubelet certificates.

**What I observed.** `kubectl top pods` returned real values and the HPA reported `cpu: 9%/70%` with 2 replicas. I did **not** run a load test, so I have not seen it scale up, and I make no claim about how it behaves under load.

**Limits.** The HPA only scales on CPU here; and it can only scale pods, so on a one-node kind cluster there is no node autoscaling and the pods can only grow as far as that node allows. Also, `replicaCount: 2` in the Deployment and `minReplicas: 2` in the HPA overlap; if they ever differ, each `helm upgrade` would briefly reset the replica count.

**Interview questions**
1. How does the HPA calculate the desired replica count, and why do CPU requests matter?
2. What problems can occur if the HPA and a Deployment's `replicas` field both try to control the count?
3. What is the difference between horizontal pod autoscaling, vertical pod autoscaling and cluster autoscaling?

## 20. The scripts, and self-healing

**What it is.** `scripts/kind-up.sh` is idempotent: it reuses the cluster if it exists, builds the image, tags it with a short hash of the image ID, loads it into the cluster with `kind load docker-image`, installs a pinned metrics-server version, then runs `helm upgrade --install --wait`. `kind-down.sh` deletes only the `usageline` cluster.

**Why these details.**
- `kind load` copies the image straight into the node, because the cluster cannot see your local Docker images and we don't want a registry. With `imagePullPolicy: IfNotPresent` the node uses the loaded copy.
- A content-based tag (not `latest`) means a rebuilt image gets a new tag, so Helm sees a change and rolls pods. With a fixed tag, the upgrade would silently do nothing.
- `helm upgrade --install` works for both the first and later runs. `--wait` makes the script fail loudly if pods never become ready.
- `set -euo pipefail` makes the script stop at the first error instead of carrying on.

**Self-healing demo (observed).** With two API pods running, I ran `kubectl delete pod` on one. The Deployment's ReplicaSet noticed the count had dropped below 2 and created a replacement. It appeared within about 2 seconds as `0/1` (running but failing its readiness probe), and was `1/1` ready about 8 seconds after the delete. During that time the other pod kept serving, and `/ready` still returned 200. This is the "declare the desired state, controllers reconcile it" model.

**Limits.** Self-healing restores pods, not data: the data survived because it is in Postgres on a PVC, not in the API pods. If the *node* died, a single-node cluster would lose everything, so this demo says nothing about node failure. The metrics-server manifest is downloaded from GitHub at run time, so the script needs internet access.

**Interview questions**
1. What is a controller / reconciliation loop in Kubernetes? Walk through what happens when you delete one pod of a Deployment.
2. How do you get a locally built image into a cluster without a registry, and why not tag it `latest`?
3. What does it mean for a script to be idempotent, and how did you make this one idempotent?

## 21. `helm lint` in CI

**What it is.** A fifth CI job runs `helm lint helm/usageline --strict` and `helm template` to render the chart. Lint catches malformed chart metadata and template mistakes; rendering catches template errors that only appear when the YAML is generated.

**Limits.** Lint and render do not prove the manifests are *valid Kubernetes objects* for the cluster version, and they do not install anything. A stronger check is to spin up a kind cluster in CI and run the real install, or to validate rendered manifests with a schema tool such as kubeconform. I did not add either; the real install was verified locally only.

**Interview questions**
1. What does `helm lint` check, and what can it not catch?
2. What is the value of `helm template` in a CI pipeline?
3. How would you test a Helm chart end to end in CI?

---

# Phase 4: Observability and load testing

Observability is being able to ask a running system "what is it doing and is it healthy?" without logging into it. The three classic signals are metrics (numbers over time), logs and traces. This phase adds metrics (Prometheus), dashboards (Grafana), alerts, and then a load test to see all of it work. Numbers quoted below were measured in this repo's runs; anything not measured is marked as such.

## 22. Application metrics: counter + histogram, labelled by route template

**What it is.** The API exposes `/metrics` in Prometheus's text format. Prometheus *pulls* (scrapes) it every 15 s. Two metrics are recorded for every request by a middleware:
- `http_requests_total{method, route, status}`: a **counter** (only goes up). Rates are computed in queries with `rate(...)`.
- `http_request_duration_seconds{method, route}`: a **histogram**. It counts how many requests fell under each latency bound (5 ms, 10 ms, ... 5 s), which lets Prometheus estimate percentiles with `histogram_quantile`.

This follows the "RED" method: **R**ate, **E**rrors, **D**uration.

**Why route templates, not URLs.** The `route` label holds `/tenants/{tenant_id}`, never `/tenants/42`. Every distinct label value creates a new time series stored in memory. Raw paths would create one series per tenant (and per scanner hitting random URLs), which is the classic *cardinality explosion* that takes down Prometheus. Requests that match no route share a single `unmatched` label. Tests check all of this: 10 distinct IDs produce no new label values, and unknown paths never appear in the output.

**Details.** `/metrics` itself is not counted. Status is recorded as 500 if the handler raises. Single process per pod, so the default in-memory registry is correct (multi-worker servers need Prometheus's multiprocess mode).

**Limits.** Histogram percentiles are *estimates* limited by bucket boundaries (p95 can only be as precise as the gap between buckets). Probe requests (`/health`, `/ready`) are counted too, so at low traffic they dominate the totals; dashboard panels exclude them for rate and latency, but the 5xx alert deliberately does not (see 26). There are no database-level metrics yet.

**Interview questions**
1. What is the difference between a counter, a gauge and a histogram? Which would you use for request latency?
2. What is metric cardinality and how can a label like `user_id` or the raw URL path break Prometheus?
3. Why does Prometheus pull metrics instead of having apps push them, and when is pushing needed?

## 23. kube-prometheus-stack, sized for a small laptop

**What it is.** `kube-prometheus-stack` is one Helm chart that installs the Prometheus Operator, Prometheus, Alertmanager, Grafana and kube-state-metrics. The **Operator** is a controller that adds new Kubernetes object types (CRDs): `ServiceMonitor` ("scrape this Service"), `PrometheusRule` ("these alert rules") and so on, so monitoring config is declared in YAML next to the app rather than in one central Prometheus config file. `kube-state-metrics` turns Kubernetes object state (replicas, readiness, requests) into metrics. Our overrides are in `monitoring/values.yaml`.

**What we turned off or shrank, and why.** The Docker VM here has about 3.8 GiB in total, shared with the kind node and, normally, two other containers, so every component got explicit requests/limits and these cuts:
- Built-in alert/recording rules off (`defaultRules.create: false`): we ship our own three alerts, and ~100 default rule groups cost memory and create noise.
- node-exporter, etcd, scheduler, controller-manager, kube-proxy, CoreDNS and API-server scrapers off. They are not needed to monitor our app, and on kind several are not reachable anyway.
- **Kept the kubelet scrape on purpose**: it exposes cAdvisor, the source of per-container CPU usage that the CPU-vs-requests panel and our autoscaling analysis depend on.
- Retention 6 h with a 400 MB size cap, and **no persistent volumes**: data is in an `emptyDir`, so restarting the Prometheus pod loses history. Fine for a demo, wrong for real use.
- Stock Grafana dashboards off; only ours is loaded.
- **Alertmanager kept.** Measured at about 49 MiB for the pod (two containers) with a 64 Mi limit on the main one, it fit the budget, and it lets us verify the full path from rule to notification. If memory had been tighter, dropping it would still leave alerts visible in Prometheus's own Alerts page; what you lose is grouping, silencing and routing to receivers.

**What went wrong (honest sizing lessons).** My first memory limits were guesses and two were too small. Both showed up as `OOMKilled` (exit 137): the Grafana sidecars at an 80 Mi limit, and later the Grafana container itself at 220 Mi, which died while I was running dashboard queries. I raised them (sidecar 128 Mi, Grafana 384 Mi) and removed the datasource sidecar entirely by provisioning the datasource directly. Measured afterwards, the Grafana pod used about 367 MiB including its sidecar, so it is still near its limits. The lesson: limits should come from measurement, and a limit set too low turns into restarts rather than a graceful slowdown.

**Limits.** This is a single replica of everything with no persistence, a default admin password (`admin`) and no TLS; it is a local learning setup, not a production monitoring design. In production you would add persistent storage, longer retention (or remote write / Thanos), HA Prometheus and Alertmanager, and real credentials.

**Interview questions**
1. What does the Prometheus Operator do, and why use ServiceMonitor objects instead of editing `prometheus.yml`?
2. What do you lose if you run Prometheus without persistent storage, and what do you do about it in production?
3. Why did you keep the kubelet/cAdvisor scrape but turn off the others? What does kube-state-metrics provide that cAdvisor does not?

## 24. ServiceMonitor, toggled in `values.yaml`

**What it is.** A `ServiceMonitor` tells Prometheus which Service to scrape, on which port and path, and how often. Ours selects the API's Service by label, scrapes the `http` port at `/metrics` every 15 s, and so Prometheus scrapes each API **pod** individually (it discovers the pods behind the Service). A confirmed result: both API pods appeared as targets in state `up`.

**The ordering problem.** A `ServiceMonitor` object only exists if the Operator's CRDs are installed. If the chart always rendered one, `helm install` would fail on a cluster without the monitoring stack. So `serviceMonitor.enabled`, `prometheusRule.enabled` and `grafanaDashboard.enabled` default to `false`, and `monitoring/usageline-values.yaml` flips them on. `kind-up.sh` checks whether the CRD exists and adds that file only if so; `monitoring-up.sh` installs the stack first and then re-runs `kind-up.sh`. Result: the app works with or without monitoring.

**Discovery gotcha.** By default the stack's Prometheus only picks up ServiceMonitors/PrometheusRules labelled with its own Helm release. We set the `*SelectorNilUsesHelmValues` options to `false` so it discovers objects from any namespace, otherwise our app's monitor in the `usageline` namespace would be silently ignored. Also expect a delay: after the objects were created it took a minute or two for the targets to appear and for the first successful scrape.

**Interview questions**
1. How does Prometheus find out which pods to scrape in Kubernetes?
2. Why is a CRD-dependent resource in a Helm chart a problem on a cluster without that CRD, and how did you handle it?
3. A ServiceMonitor exists but no target shows up in Prometheus. What do you check?

## 25. A Grafana dashboard as code

**What it is.** The dashboard is a JSON file (`helm/usageline/files/dashboard.json`) wrapped into a ConfigMap labelled `grafana_dashboard: "1"`. A sidecar container in the Grafana pod watches for ConfigMaps with that label (in all namespaces) and loads them. The dashboard therefore deploys with the app, lives in git and can be reviewed in a pull request, instead of being hand-built in the UI and lost with the pod. The datasource is referenced by a fixed `uid` (`prometheus`) so the JSON stays portable.

**Panels.** Request rate by route (probes excluded); 5xx error ratio; p50 and p95 latency; pod count (available, desired by the Deployment, desired by the HPA); and CPU used vs CPU requests vs the HPA's 70% target line vs the limit.

**How I verified it.** Grafana found the dashboard by its search API (`Usageline API`), and I ran **all 12 panel queries through Grafana's own query API** over the load-test window; every one returned data. I did not view it in a browser, so I have not checked how the panels look visually. The dashboard is 5 panels, kept small on purpose.

**Why "CPU vs requests".** The HPA measures CPU as a percentage of each pod's *request*, not of the node or the limit. Plotting usage next to the request and the 70% line shows exactly why (and when) it scales.

**Limits.** Namespaces and the deployment name are hard-coded in the queries; a dashboard variable would be better. Editing the dashboard in the Grafana UI does not write back to git.

**Interview questions**
1. What is the advantage of provisioning dashboards from files/ConfigMaps rather than building them in the UI?
2. Why is CPU usage shown relative to the pod's request when explaining autoscaling?
3. What does a `histogram_quantile(0.95, ...)` query actually compute, and how can it mislead?

## 26. Alerts: PrometheusRule, and how each was verified

**What it is.** A `PrometheusRule` holds alert rules. Prometheus evaluates each expression every 30 s; when it is true it becomes *pending*, and after staying true for the `for` duration it becomes *firing* and is sent to Alertmanager. The `for` clause prevents flapping on brief blips. Thresholds are in `values.yaml`.

| Alert | Fires when | `for` |
| --- | --- | --- |
| `UsagelineHigh5xxRate` | 5xx responses are over 5% of all requests (5 min window) | 2 m |
| `UsagelineHighLatencyP95` | p95 latency of non-probe routes is over 0.5 s (5 min window) | 5 m |
| `UsagelinePodsNotReady` | a Running pod in the namespace is not Ready | 2 m |

**How I verified each one loads.** Through the Prometheus API (`/api/v1/rules`): all three appeared with `health: ok`, no `lastError`, and state `inactive`. I also ran the underlying expressions by hand (for example the `up` and pod-readiness queries) and they returned values, so they are not silently matching nothing.

**How I verified they can fire.**
- `UsagelineHigh5xxRate` and `UsagelinePodsNotReady`: I scaled the dev Postgres to zero. `/ready` started returning 503, both API pods went unready, and about 200 s later both alerts were *firing* (first *pending*, then firing) and Alertmanager's API listed them as active. I then scaled Postgres back up; the data was intact thanks to the PVC.
- `UsagelineHighLatencyP95`: **loaded and evaluating, but never fired.** Under the load test the server-side p95 peaked at 0.246 s, below the 0.5 s threshold, and the alert was never even pending. So I have shown it is valid and evaluating, but not that it fires.

**Design choices and limits.**
- The 5xx ratio includes the probe routes. That is intentional: a database outage shows up as `/ready` 503s, which is a real failure. The cost is that at low real traffic the ratio is dominated by probe requests, and during my test the ratio reached about 50% shortly after the fault injection (it is a 5-minute window, so the number lingers after recovery).
- The not-ready rule joins on "phase = Running" so completed Job pods (which report not-ready) do not trigger it.
- Alerts only go to Alertmanager. No receiver (Slack, email, PagerDuty) is configured, so nothing would actually page anyone.
- Thresholds are first guesses, not based on an SLO.

**Interview questions**
1. What is the difference between pending and firing, and why does the `for` clause exist?
2. Why alert on symptoms (error rate, latency) rather than only on causes (CPU is high)?
3. How would you test that an alert rule works before an incident, without breaking production?

## 27. The k6 load test

**What it is.** `loadtest/k6.js` simulates users. Each virtual user (VU) loops: create a tenant, record 3 usage events, generate an invoice, read it back, then pause 200–500 ms. Load ramps 0 → 5 VUs (30 s), → 20 (1 min), → 40 (2 min hold), → 0 (30 s): four minutes in total, against `localhost:8081`. `setup()` creates the plan once (and reuses it on later runs). `thresholds` define pass/fail (error rate under 1%, p95 under 1 s).

**Why this shape.** A ramp lets you see where behaviour changes rather than just a single number; a plateau is long enough for the autoscaler (which acts on 15-second cycles) to react; and 40 VUs is modest, because the load generator, the kind node and the monitoring stack all share one laptop. The load generator runs on the same machine as the system under test, so it competes for CPU, which makes absolute numbers pessimistic and non-portable.

**Limits.** One scenario, uniform user behaviour, no think-time variation beyond a small jitter. The test writes real rows: this run created about 9,400 tenants and roughly three times as many usage events in the dev database, which is harmless but means each run leaves data behind. The thresholds are checks for this run, not a performance claim.

**Interview questions**
1. What is the difference between a load test, a stress test and a soak test?
2. Why can results be misleading when the load generator runs on the same machine as the system under test?
3. What is a threshold in k6 and how would you use one in CI?

## 28. What happened under load (observed)

Measured in a single run on this laptop. These numbers describe this setup only.

| What | Observed |
| --- | --- |
| Requests | 56,509 HTTP requests in 4 minutes (k6: 235 req/s average over the whole run, including ramp up/down), 9,418 complete iterations, max 40 VUs |
| Peak throughput | 367 req/s (Prometheus, 30 s window, probes excluded) |
| Errors | 0.00% failed (k6); no non-probe 5xx series in Prometheus during the run |
| Latency | k6 client-side p95 149 ms (median 4.9 ms, max 2.57 s); server-side p95 peaked at 0.246 s (1-minute window) |
| HPA | 2 → 4 replicas at 21:56:41, → 5 (its maximum) at 21:56:56 |
| CPU | HPA's metric rose 13% → 31% → 62% → 107% (21:55:56–21:56:26), reached 196% at the first scale-up, then stayed between about 155% and 270% of requests at 5 replicas. Peak total usage was 1.31 cores across the API pods vs 0.5 cores requested |
| Memory | The kind node rose from about 2.33 to 2.70 GiB (of the VM's 3.83 GiB) during the run |

**How the HPA behaved, and why I did not change anything.** It scaled, so there was nothing to investigate on the "did it scale" question. First reaction came roughly 60–70 s after the load began, which is the sum of metrics-server's sampling interval, the HPA's 15 s sync loop and the ramp itself. It went from 2 to 4 in one step, consistent with the default scale-up behaviour that limits how fast replicas can grow. After that CPU stayed *above* the 70% target even at 5 pods, meaning the limit that bound the system was `maxReplicas: 5`, not the autoscaler's responsiveness. The pods also stay under their 500m CPU limit (about 260m each at peak), so they were not CPU-throttled. At the end of my observation window (shortly after the load stopped) the HPA still showed 5 replicas with CPU at 17%; I did not wait for it to scale back down, so I have not observed the scale-down.

**Why it was easy to trigger.** The CPU request is only 100m while the limit is 500m, so a pod using a fraction of a core is already "over 100% of request". That makes the HPA sensitive. Requests, limits and the HPA target together define the behaviour; they are tuned here to demonstrate scaling on a laptop, not derived from production capacity planning.

**Limits.** One run, one machine, shared resources. Not a benchmark: it says nothing about performance on other hardware, and there is no comparison to a baseline or to a different replica count. Peak throughput here is probably limited by the laptop (and by the 5-replica cap) rather than by the application's true ceiling, but I did not test that.

**Interview questions**
1. How does the HPA decide how many replicas it needs, and why can it take over a minute to react?
2. What is the relationship between CPU requests, CPU limits and the HPA's utilisation target? What happens to a pod at its CPU limit?
3. Under load the HPA was stuck at its maximum with CPU still above target. What would you look at next?

## 29. Runbook, scripts and CI

- **`docs/RUNBOOK.md`:** for each alert, what it means, how to diagnose it (dashboard panels and `kubectl` commands) and what to do. Alerts without a response procedure just create anxiety; each alert also carries a `runbook` annotation pointing at its section.
- **`scripts/monitoring-up.sh`:** installs the stack with a pinned chart version (reproducible), then re-runs `kind-up.sh`. It prints the port-forward commands (Grafana on 3000, Prometheus on 9090, Alertmanager on 9093).
- **CI:** the helm job now lints the chart both with defaults and with the monitoring values, renders both, and renders `kube-prometheus-stack` with our `monitoring/values.yaml`, so a typo in those files fails the build. This checks that the YAML renders; it does not prove the objects are valid on a cluster or that the stack fits in memory (I found that out the hard way, above).

**Interview questions**
1. What belongs in a runbook entry for an alert, and why link it from the alert itself?
2. Why pin the version of a third-party Helm chart?
3. What can `helm template` catch in CI, and what only shows up when you install on a real cluster?

## 30. Follow-up: Grafana OOMKilled again, and a Helm/HPA conflict

**Finding.** While viewing the dashboard through a port-forward, the Grafana pod restarted twice. `kubectl describe pod` and the container statuses showed the restarting container was the main **`grafana`** container (limit 384 Mi, last state `OOMKilled`, exit code 137), not the `grafana-sc-dashboard` sidecar (0 restarts). At that moment `kubectl top` showed Grafana at about 274 Mi and the sidecar at 81 Mi, so the 384 Mi limit was only about 110 Mi above its idle usage, and a burst while rendering a dashboard was enough to cross it. This is the same failure as in section 23, and it shows that my previous fix (220 Mi to 384 Mi) was sized from a single reading rather than from behaviour while someone actually uses the dashboard.

**Change.** In `monitoring/values.yaml` the Grafana container now has a 512 Mi limit and a 192 Mi request (the sidecar stays at 128 Mi). Headroom: the Docker VM has 3.83 GiB; the kind node was using about 2.5 GiB, so roughly 1.3 GiB was spare while the other two containers on this machine were stopped, and about 0.6 GiB if they run again (they used about 0.7 GiB earlier). Raising the limit by 128 Mi fits either way, but it is a ceiling for spikes, not a prediction that Grafana will use that much.

**What I observed afterwards.** After redeploying with `scripts/monitoring-up.sh`, I simulated a person keeping the dashboard open: every 10 seconds (the dashboard's own refresh interval) a script loaded the dashboard definition and ran all 12 panel queries through Grafana's API, for about 3 minutes (18 refreshes, 12 of 12 panels returned data every time).
- Restart count stayed at **0** for both containers; the pod was 5 minutes old at the last check and the last state of both containers was empty.
- Grafana's memory was **not flat**: 249 Mi at the start, 301 Mi at about 45 s, 325 Mi at about 110 s and 339 Mi at about 3 minutes (345 Mi at the final check). That is under the 512 Mi limit, but it was still creeping up when I stopped, so 3 minutes does not show that it plateaus.

**Limits of this check.** The simulation used API calls, not a browser, so it exercises Grafana's server side (which is what the memory limit applies to) but not a person's browser session with its own panel rendering and variable changes. A longer soak, or watching memory over an hour, is the real test. If it keeps growing, the next steps would be to look at Grafana's own metrics or reduce what it caches, rather than raising the limit again.

**A second problem found during the redeploy.** `monitoring-up.sh` failed at its second step with a Helm 4 error: a *server-side apply conflict* on the Deployment's `.spec.replicas`. Helm now uses Kubernetes server-side apply, which tracks which controller owns each field. Our chart sets `replicas` in the Deployment, but the HPA (via the controller manager) also changes it, so after the HPA scaled to 5 a later `helm upgrade` was rejected rather than silently overwriting it. I added `--force-conflicts` to the `helm upgrade --install` in `scripts/kind-up.sh`, which lets Helm take the field back. This is a trade-off, not a clean fix: it resets the replica count to the chart's value on every upgrade, so an upgrade during a traffic peak briefly drops replicas until the HPA scales up again. The conventional fix is to leave `replicas` out of the Deployment when an HPA is enabled; I did not do that here because I have not tested a fresh install without it (the HPA needs working metrics to act).

Side observation: after the load test and the redeploys, the HPA was back down to 3 replicas at 7% CPU on its way to 2. So I did eventually observe scale-down, but only partially (5 to 3, not yet at the minimum of 2); the first "ScaleDownStabilized" condition in its description shows the default stabilisation window delaying it.

**Interview questions**
1. Exit code 137 and `OOMKilled`: what does each tell you, and how do you tell which container in a multi-container pod was killed?
2. How would you choose a memory limit for a service like Grafana whose usage depends on what people do with it? What would you monitor?
3. Why can `helm upgrade` conflict with an HPA over `spec.replicas`, and what are two ways to resolve it?
