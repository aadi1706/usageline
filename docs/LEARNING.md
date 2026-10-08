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

---

# Phase 5a: Terraform for AWS (validate-only)

Terraform is "infrastructure as code": you describe cloud resources in `.tf` files, and `terraform apply` makes AWS match them. **Nothing in this phase has been planned or applied.** There are no AWS credentials on this machine, and the job in CI has none either. What *was* run: `terraform fmt`, `terraform validate` (which checks syntax and types and never contacts AWS), `tflint` and `checkov` (static analysers that read the code). So everything below describes code that is well-formed and passes static checks; it has not been proven to create working infrastructure. Cost figures are in [COST_ESTIMATE.md](COST_ESTIMATE.md) and are estimates.

## 31. Layout: modules, environments, bootstrap

**What it is.** `terraform/modules/*` hold reusable building blocks (`vpc`, `ecr`, `sqs`, `rds`, `iam`, `eks`), each with `variables.tf` (inputs), `outputs.tf` (what other modules can use), `main.tf`, `versions.tf` and a short README. `terraform/envs/dev` and `envs/prod` are thin "root modules" that call those modules with different settings. `terraform/bootstrap` creates the state bucket (see 32).

**Why.** One definition of "a VPC" or "a database" is reused by both environments, so dev and prod differ only in the values passed in (NAT on/off, Multi-AZ, node counts, deletion protection), which makes drift between them easy to see in a diff. Modules expose only what callers need, and outputs wire them together (the VPC's subnet IDs feed RDS and EKS; the EKS security group feeds the database's allow-list; the queue ARN and database secret ARN feed the IAM role).

**Choices.**
- Modules are written with plain AWS resources instead of pulling a community module, so every setting is visible and reviewable in this repo.
- Provider versions are constrained (`aws ~> 6.0`, `tls ~> 4.0`) and the exact versions are pinned by committed `.terraform.lock.hcl` files, generated for both macOS (arm64) and Linux (CI), so everyone and CI download identical, hash-verified providers.
- Dev has EKS and NAT **off** by default (they bill by the hour). A validation rule on `enable_eks` fails if you turn EKS on without NAT, because worker nodes sit in private subnets and need outbound internet to join the cluster and pull images. `module.eks` uses `count`, and consumers read it with `one(module.eks[*].x)` or `module.eks[*].x` so that nothing breaks when it is absent.

**Limits.** I could not test that cross-variable validation rule by planning (planning needs credentials), so it has been reviewed but not exercised. Two near-identical environment folders will drift unless someone keeps them in sync; at larger scale people use a tool like Terragrunt or workspaces.

**Interview questions**
1. What is the difference between a Terraform module and a root module, and why split code into modules?
2. What does `.terraform.lock.hcl` do, and why commit it?
3. Why would you use `count` on a module call, and what problems does that create for anything that references it?

## 32. Remote state, and which locking method

**What it is.** Terraform records what it has created in a *state file*. If it lives on one laptop, nobody else can safely change the infrastructure, and losing the file is a disaster. Both environments store state in an S3 bucket (`backend "s3"` in `backend.tf`, with a different `key` for dev and prod). The bucket itself comes from `terraform/bootstrap`, which uses local state: a chicken-and-egg problem (you cannot store state in a bucket that does not exist yet), so that folder is applied once by hand.

**Bucket hardening.** Versioning (to recover from a bad write), encryption with a dedicated KMS key that rotates, all public access blocked, a policy denying non-TLS requests, and old versions expiring after 90 days. `force_destroy = false` refuses to delete a bucket that still holds state.

**Locking: S3 native locking (`use_lockfile = true`).** While one person runs `apply`, Terraform writes a small `.tflock` object next to the state using an S3 conditional write; a second run sees it and stops, so two people cannot corrupt the state at once. I chose this because it needs only the bucket: the older approach also required a DynamoDB table (extra resource, extra permissions, extra cost), and current Terraform treats DynamoDB-based locking as deprecated. It needs Terraform 1.10 or newer, which `required_version` enforces.

**How the bucket name stays out of code.** A `backend` block cannot use variables, so `bucket` and `region` are passed at init time (`terraform init -backend-config=backend.hcl`); `backend.hcl.example` shows the format and `backend.hcl` is git-ignored. For `validate` and CI the backend is skipped (`init -backend=false`), which is why no credentials are needed.

**Limits.** The bootstrap state is local, so it must be kept safe (or imported later); it is small and rarely changes. No cross-region replication or access logging on the state bucket (checkov skips with reasons in the code). Whoever runs Terraform needs permissions on the state keys and the KMS key; those are described in the bootstrap README, not created here.

**Interview questions**
1. What is in a Terraform state file, why is it sensitive, and what goes wrong without locking?
2. How does S3 native state locking work, and why is it replacing DynamoDB locking?
3. What is the bootstrap problem with remote state and how do you solve it?

## 33. VPC: two AZs, optional NAT

**What it is.** A private network across two availability zones (separate data centres in a region), with a public and a private subnet in each. Public subnets route to an internet gateway; private subnets do not. A **NAT gateway** lets private resources start outbound connections (for example to pull images) without being reachable from the internet.

**Why NAT is optional and off in dev.** A NAT gateway costs money for every hour it exists (about $33 a month each at the price I assumed, before data charges), even when idle. Prod turns it on with one per AZ so losing an AZ does not cut off the other; dev leaves it off. A free S3 gateway endpoint keeps S3 traffic (including ECR image layers) off the NAT.

**Other choices.** The default security group is emptied so nothing silently relies on it; public subnets never auto-assign public IPs; flow logs record network traffic to CloudWatch; subnets carry the tags Kubernetes needs to find them for load balancers.

**Limits.** The subnet layout is fixed at /20 slices of the VPC CIDR and exactly two AZs. Private subnets in dev have no internet at all, so nothing there can reach out (which is fine for RDS but is why EKS needs NAT). No VPC interface endpoints (each costs about $7 a month per AZ). No network ACLs beyond defaults. Flow logs are unencrypted with a customer key (skip documented).

**Interview questions**
1. What makes a subnet public vs private in AWS?
2. What does a NAT gateway do, what does it cost you, and what are cheaper alternatives?
3. Why spread subnets across two AZs, and what does a single NAT gateway do to that design?

## 34. SQS with a dead-letter queue

**What it is.** A queue for usage events, plus a **dead-letter queue (DLQ)**. If a consumer fails to process a message 5 times (`max_receive_count`), SQS moves it to the DLQ instead of retrying forever. A "poison" message that always crashes the consumer therefore stops blocking the queue, and it is kept for 14 days so someone can inspect it.

**Details.** `visibility_timeout` (60 s) must be longer than the consumer's processing time, or a message is delivered twice. The DLQ accepts messages only from the main queue (`redrive_allow_policy`). Both queues are encrypted at rest and carry a policy that denies non-TLS access; that policy's `sqs:*` is a Deny statement, so it can only remove access, and the comment in the code says so.

**Limits.** No alarm on the DLQ depth is created here, which is what actually makes a DLQ useful. Standard queues deliver at least once and may reorder, so consumers must be idempotent; FIFO queues were not chosen.

**Interview questions**
1. What is a dead-letter queue and what problem does it solve?
2. What is the visibility timeout and what happens if it is too short?
3. Why must consumers of a standard SQS queue be idempotent?

## 35. ECR with scanning and a lifecycle policy

**What it is.** A private registry for the API's Docker image. Scan-on-push checks each image for known vulnerabilities. Tags are **immutable**, so `v1.2.3` can never be silently overwritten and a deployment always means the same bytes. A lifecycle policy deletes untagged images after 7 days and keeps only the 20 newest images, so storage cost does not grow without bound.

**Limits.** Basic scanning only reports; nothing blocks a vulnerable image from being deployed. Immutable tags mean a CI pipeline must always push unique tags (a commit SHA), never `latest`. Encryption uses AWS's managed key unless a key is passed in (checkov skip documented). Nothing pushes to this registry yet: our CI builds the image but does not publish it.

**Interview questions**
1. Why make image tags immutable, and what does it force your CI to do?
2. What does ECR scan-on-push actually protect you from, and what does it not?
3. What does a lifecycle policy do and what could go wrong if it is too aggressive?

## 36. RDS PostgreSQL and the password

**What it is.** A `db.t4g.micro` (smallest Graviton class) PostgreSQL instance in private subnets, encrypted at rest, not publicly accessible. Only the security groups you list may connect on port 5432, with no CIDR rules.

**The password.** With `manage_master_user_password = true`, RDS generates the master password itself and stores it in AWS Secrets Manager. The password therefore never appears in the Terraform code, in a variable, or in the state file, and the application reads the secret at runtime (the IAM module lets exactly one role read exactly that secret). This was a requirement, and it is also the only approach that keeps the password out of state.

**Other settings.** A parameter group forces TLS (`rds.force_ssl`) and logs DDL plus any statement slower than 1 second; IAM database authentication, CloudWatch log export, enhanced monitoring, automated backups, storage autoscaling and deletion protection are on. Dev turns off Multi-AZ and deletion protection and skips the final snapshot (documented checkov skips apply to dev only); prod keeps them on.

**Limits.** Performance Insights is off (skip documented). A single-AZ dev database has no failover. The managed secret is not automatically rotated in our code. The instance class and storage are sized for a demo, not measured against real load.

**Interview questions**
1. How does `manage_master_user_password` keep the password out of Terraform state, and what are the alternatives?
2. What does Multi-AZ give you, and how is it different from a read replica?
3. Why put a database in a private subnet and allow access by security group instead of by IP range?

## 37. EKS and IRSA

**What it is.** A managed Kubernetes control plane with a small managed node group (default 2 x `t3.medium`; prod 2 to 4 nodes, dev 1 to 2). **IRSA** (IAM Roles for Service Accounts) lets an individual Kubernetes pod get its own AWS permissions: the cluster has an OIDC identity provider, a pod's service account token is exchanged for temporary credentials of a specific IAM role, and the role's trust policy says which service account may assume it. The alternative, giving the node's role broad permissions, would hand every pod on the node the same access.

**Choices.** Kubernetes Secrets are envelope-encrypted with a dedicated rotating KMS key; all five control plane log types go to CloudWatch; nodes require IMDSv2 with a hop limit of 1 (pods cannot reach the node's credentials) and have encrypted disks; the node role carries only the three AWS-managed policies EKS documents. The API endpoint is reachable from the internet but only from CIDRs you list, and the module **rejects `0.0.0.0/0`** by validation.

**Limits (important).** The public endpoint is a convenience: with no VPN or bastion, a private-only endpoint would make the cluster unreachable from a laptop, so checkov's two public-endpoint checks are skipped with that reason. Not included: cluster add-ons, the cluster autoscaler or Karpenter, the AWS Load Balancer Controller, or a pod security baseline. The Kubernetes version default (1.33) must be checked against what EKS supports when you actually apply. Validate cannot prove the node group will register; that depends on networking (NAT) at apply time.

**Interview questions**
1. What problem does IRSA solve, and how does a pod end up with temporary AWS credentials?
2. Why is it a risk to give the node IAM role broad permissions?
3. What are the trade-offs of a public vs private EKS API endpoint?

## 38. Least-privilege IAM

**What it is.** The application's IRSA role can assume only from the `usageline` service account in the `usageline` namespace (the trust policy checks both the token's `sub` and `aud` claims; without `sub`, any service account in the cluster could assume it). Its permission policy lists exact actions on exact resources: send/receive/delete/get-attributes on the one queue, and read on the one database secret. There are no wildcard actions or resources there.

**Where wildcards remain, and why.** There are three, each justified in a comment: a `Deny` on `sqs:*` and another on `s3:*` for non-TLS traffic (a Deny can only remove access), and `kms:*` in each KMS key policy, which is the standard "let IAM decide" statement AWS itself creates (in a key policy `Resource: "*"` means "this key"). Other roles use AWS-managed policies for services that need them (EKS cluster and node roles, RDS enhanced monitoring).

**Limits.** No permission boundaries, no service control policies, and no review of the AWS-managed policies' breadth (they are broad by design). The roles for CI to push images (OIDC federation from GitHub) are not created.

**Interview questions**
1. What does least privilege mean in practice, and how do you apply it to a role that reads one SQS queue?
2. Why does an IRSA trust policy need a condition on the `sub` claim?
3. When is a wildcard action in an IAM policy acceptable, and how do you document it?

## 39. Static analysis: what ran, what it found, and what it cannot prove

**What ran.**
- `terraform fmt -check -recursive`: passed. `terraform init -backend=false` and `terraform validate` in `bootstrap`, `envs/dev` and `envs/prod`: all valid, locally and in CI.
- **checkov** (security/policy scanner): the final result is 0 failed checks (248 passed, 19 skipped entries, which come from 12 distinct skip comments in the code, several counted once per environment) on checkov 3.3.26, and 0 failed on the older 3.3.20 I have locally.
- **tflint** with the Terraform "recommended" and AWS rulesets: **run in CI only** (no issues reported). It is not installed on this machine: Homebrew no longer carries it and it is not on PyPI, and the only other official route is downloading a release binary, which I did not do without asking you.

**What went wrong, and what it taught.**
1. **My local result was not the CI result.** CI installed a newer checkov (3.3.26, more checks) than my local one (3.3.20) and failed with 6 findings I had not seen. I reproduced them locally in a throwaway virtualenv with the same version, then fixed the real ones: RDS query logging and TLS enforcement (a parameter group), and explicit KMS key policies. CI now **pins checkov's version**, because an unpinned scanner can turn the build red on its own when it gains checks; upgrading becomes a deliberate change.
2. **Skips can be dead code.** I removed three skip comments after concluding checkov 3.3.20 never evaluated those checks, then CI's newer version did flag them. They are back as real skips. Lesson: whether a suppression is needed depends on the tool version, so test with the version CI uses.
3. **A skip can be scoped.** The "no Multi-AZ" and "no deletion protection" skips are placed on the *dev module call*, not inside the module, and checkov reported them only for dev, so prod still enforces those checks.
4. **The KMS key policy needed `jsonencode`, not a policy document.** Writing it as an `aws_iam_policy_document` made checkov judge it as a general IAM policy (wildcard action, wildcard resource) and fail three IAM checks; as a plain key policy it passes.

**Skips that remain (each has a reason in the code):** no customer-managed key for ECR and CloudWatch log groups; Performance Insights off on the database; EKS public endpoint restricted by CIDR instead of private-only (the two public-endpoint checks); dev-only no Multi-AZ and no deletion protection; state bucket without access logging, cross-region replication or event notifications.

**What none of this proves.** `validate` and the scanners read code; they cannot tell you the IAM policy is sufficient for the app to work, that the AMI/Kubernetes version exists, that names are globally unique (S3 bucket names), that you are within account quotas, or that `apply` will succeed. Only a `plan` against a real account (and an `apply`) answers those, and neither was run.

**Interview questions**
1. What is the difference between `terraform validate`, `terraform plan` and a security scanner like checkov? What does each catch?
2. A scanner passes on your laptop but fails in CI. What do you check first, and how do you prevent it?
3. How do you decide whether to fix a scanner finding or suppress it, and how should a suppression be written?

## 40. CI job and the cost estimate

**CI.** A `terraform` job runs `fmt -check`, `init -backend=false` plus `validate` in the three folders, `tflint` (with the AWS plugin pinned to 0.49.0), and checkov (pinned). It configures no AWS credentials at all, so even a bug in the pipeline cannot touch an account. First run: tflint passed but checkov failed (see 39); after the fixes the job passed.

**Cost.** [COST_ESTIMATE.md](COST_ESTIMATE.md) works through the sizes chosen: roughly $17 a month for the default dev, about $160 for dev with EKS and NAT, and about $245 for prod. It is an **estimate**: the unit prices are my assumptions of approximate list prices, not fetched, and usage-based charges (data transfer, NAT processing, logs) are excluded or guessed. About two thirds of the prod figure is EKS plus NAT, which is why those two are the on/off switches in dev.

**Interview questions**
1. Why should a validate-only CI job run with no cloud credentials, and what would you add when you want it to run `plan`?
2. How would you estimate the cost of infrastructure before building it, and how would you check the estimate afterwards?
3. Which parts of this setup would you remove first to cut cost, and what do you lose by doing so?

---

# Phase 5b: Terraform on the local kind cluster

Phase 5a described AWS infrastructure that was only validated. This phase uses Terraform for something that can be *applied for real and for free*: the Helm releases on the local kind cluster. `terraform/envs/local` uses the `helm` and `kubernetes` providers instead of AWS.

## 41. A Terraform environment pointed at one cluster only

**What it is.** `terraform/envs/local` declares the two namespaces (`kubernetes` provider) and two Helm releases (`helm` provider): `kube-prometheus-stack` installed from the community repository with a pinned chart version and `monitoring/values.yaml`, and the `usageline` chart from this repo with `monitoring/usageline-values.yaml`, an image tag, and the HPA maximum as inputs. The usageline release `depends_on` the monitoring one, because the Prometheus Operator's CRDs must exist before the chart's `ServiceMonitor` and `PrometheusRule` objects can be created.

**Making it unable to touch another cluster.** Two layers:
1. Both providers set `config_context = "kind-usageline"` as a **literal**, not a variable. If that context does not exist in the kubeconfig, the providers fail; they never fall back to whichever context happens to be current (the usual way an `apply` lands on the wrong cluster).
2. A `precondition` on a `terraform_data` resource reads the cluster's nodes and fails unless every node name starts with `usageline-`, which is how kind names the nodes of this cluster. Namespaces depend on it, so nothing is created if the check fails. It guards against a context that has the right name but points somewhere else.

**Other choices.**
- **State is local** (`terraform.tfstate`, git-ignored before the first `init`), because this manages a throwaway local cluster. State here can contain rendered chart values, so it must never be committed. This is the opposite choice from the AWS environments, which use a remote, locked, encrypted bucket.
- **Provider versions are pinned** with `~>` constraints and exact versions plus hashes in the committed `.terraform.lock.hcl` (Linux and macOS), so CI and laptops use identical providers.
- **Terraform does not build the image, create the cluster, or install metrics-server.** Those stay in `scripts/` because they are imperative steps (docker build, `kind load`) that Terraform does not model well. The image tag is passed in as a variable. This split is a real limit: "terraform apply" alone cannot bring up the whole stack from nothing.
- The namespaces are created by the `kubernetes` provider rather than by `create_namespace` on the Helm release, so Terraform, not a Helm side effect, owns them and can show them in a plan.

**A bug the guard caught in itself.** My first version of the precondition used `node.metadata.name`, but the provider returns `metadata` as a one-element list. `terraform validate` passed (the shape of that data is only known once Terraform has read the cluster), and the first `plan` then failed with "Unsupported attribute". Because a precondition that errors blocks everything that depends on it, the guard *failed closed*: it refused to proceed rather than silently allowing the run. The fix is `node.metadata[0].name`. Lessons: `validate` cannot check expressions over data that is read at plan time, and a safety check should be written so that its own failure stops the run. Plan files (`tfplan`) can contain rendered values, so they are git-ignored too.

**How to run it.** `TAG=$(./scripts/kind-bootstrap.sh)`, then in `terraform/envs/local`: `terraform init`, `terraform plan -var image_tag=$TAG -out=tfplan`, `terraform apply tfplan`. The same steps are in the README. Use `./scripts/kind-down.sh` to delete the cluster; delete `terraform.tfstate*` in `terraform/envs/local` before applying to a new cluster: the old state only records releases on a cluster that no longer exists. (I have not tested what Terraform does if you leave it in place.)

**Limits.** The `helm_release` resource only notices changes to its inputs (chart version, values, set values); editing a template inside the local chart directory without changing the chart's `version` is not a change Terraform can see. The Helm hooks in our chart (the migration Job, the dev Postgres created as a pre-install hook) are not tracked as release resources, so Terraform does not know about them. The precondition checks node names, not the cluster's identity cryptographically.

**Interview questions**
1. What are the ways a `terraform apply` can end up on the wrong cluster, and how does hard-coding the provider context and adding a precondition address them?
2. Why does the usageline release need `depends_on` on the monitoring release when there is no attribute reference between them?
3. When is local state acceptable, and what do you lose compared with a remote locked backend?

## 42. Where Terraform stops: splitting the bootstrap from the releases

**What happened.** When I came to hand the existing Helm releases to Terraform, the kind cluster had been deleted, so there was nothing to import. The decision became: how does the cluster get back, and where does Terraform take over?

**Decision.** `scripts/kind-up.sh` used to do everything: create the cluster, build and load the image, install metrics-server, and `helm upgrade --install`. I split out `scripts/kind-bootstrap.sh`, which does only the first three and prints the loaded image tag as its only stdout (progress goes to stderr). `kind-up.sh` now calls it and then runs Helm, so the old workflow is unchanged; the Terraform workflow runs the bootstrap and then `terraform apply -var image_tag=<tag>`.

**Why not `terraform import` for existing releases.** On a fresh cluster there is nothing to import. In general, importing a `helm_release` brings in only some attributes (the values you passed are not recorded), so the first plan after an import usually shows an in-place update that re-applies the chart. Creating from scratch is cleaner, and it proves the code can build the whole stack from nothing, which is the point of infrastructure as code. Import is the right tool when you cannot afford to recreate something (a production database, say).

**Where the boundary is, and why.** Docker builds, `kind load` and cluster creation are imperative, local-machine actions; Terraform models desired state of resources it can read back. Putting them in a shell script keeps Terraform's plans honest, at the cost that "terraform apply" alone cannot start from a missing cluster.

**Limits.** The tag is a hand-off between two tools (a value copied from the script's output to a variable), so a stale tag causes `ImagePullBackOff` rather than a Terraform error. metrics-server is applied with `kubectl`, so Terraform does not own it, and nothing in Terraform detects it being missing (the HPA would just show `<unknown>` CPU).

**Interview questions**
1. When would you use `terraform import` instead of recreating a resource, and what problems does importing a Helm release have?
2. How do you decide which steps belong in Terraform and which in a script?
3. A teammate runs `terraform apply` on a fresh machine and the pods are in `ImagePullBackOff`. What are the likely causes in this setup?

## 43. Applying for real, and a drift demonstration (observed)

All of this ran against the local kind cluster only; the AWS folders were not touched.

**First apply.** `terraform plan` showed `5 to add, 0 to change, 0 to destroy`: the cluster guard, the two namespaces and the two Helm releases. `terraform apply` of that saved plan took about 7 minutes in total (the monitoring stack 4m57s, the usageline chart 2m16s, most of which is waiting for pods and the migration hook Job). Afterwards: 2 API pods, Postgres and all 5 monitoring pods were `Running`; `helm list` showed `kps` and `usageline` as `deployed`; `curl localhost:8081/health` returned `{"status":"ok"}` and `/ready` returned `{"status":"ready"}` (both HTTP 200); the HPA reported `cpu: <unknown>` for the first seconds (metrics not yet collected) and `9%/70%` shortly after. A plan with no code change then reported "No changes".

**Changing one value in code.** I changed the default of `hpa_max_replicas` from 5 to 4. The plan was `0 to add, 1 to change, 0 to destroy`: only `helm_release.usageline`, updated in place, and the only real input difference was `set` value `hpa.maxReplicas: "5" -> "4"`. The other `~` lines in that plan are the provider marking computed release metadata (revision, timestamps, rendered values) as "known after apply"; they are noise, not extra changes. The monitoring release and namespaces were not in the plan. Applying took 6 seconds: the live HPA became `max=4`, `helm list` showed `usageline` at revision 2, the API pods were not restarted (same pod names and ages, since nothing in the Deployment changed), and `/health` and `/ready` still returned 200. A plan afterwards said "No changes".

**What Terraform does NOT see (observed).** To test real drift I patched the HPA by hand with `kubectl` (max 4 to 3) and ran `plan` again: it still said "No changes". `helm_release` compares the values you give it with what it saved in state; it does not read the live Kubernetes objects, so an out-of-band edit is invisible until the chart's inputs change (and even then Helm only re-renders from the chart). I restored the live value to 4 afterwards. This differs from most AWS resources, where a refresh reads the real object and plan shows the difference.

**Why this still beats applying by hand.** The change was reviewed as a code diff, the plan showed exactly what would change before anything happened, and the saved plan guaranteed that `apply` did exactly that. The cost was a heavier tool for a one-line change.

**Limits.** "Drift" in the Helm sense is only detected for inputs. To get real drift detection for Kubernetes objects you would manage them directly with the `kubernetes` provider (resource-by-resource), use `helm diff`, or run a GitOps controller that continuously reconciles. Saved plans can go stale if anything changes between plan and apply (Terraform refuses to apply a plan if state changed underneath it).

**Interview questions**
1. What does it mean for Terraform to detect drift, and why did it not notice the manual `kubectl patch`?
2. Why save a plan with `-out` and apply that file instead of running `apply` directly?
3. The plan showed many `known after apply` lines for a one-value change. How do you tell real changes from provider noise?

## 44. CI for the local environment

**What changed.** The `terraform` CI job now runs `terraform init -backend=false` and `terraform validate` in `terraform/envs/local` as well. The format check, `tflint --recursive` and checkov already scan the whole `terraform/` tree, so the new folder is covered by them without further changes; only the explicit list of folders in the validate loop needed the new entry. I ran every one of those commands locally first (format, validate in all four folders, tflint, checkov), all clean.

**What CI can and cannot say about this folder.** It proves the configuration is syntactically valid, correctly typed and consistent with the provider schemas (including the pinned provider versions in the lock file, which were generated for Linux so CI can use them). It does **not** run `plan` or `apply` here: that needs a kind cluster, which a CI runner does not have, so everything in sections 42 and 43 (real apply, drift behaviour) was verified by hand on my machine only. A bug like the cluster guard's `metadata[0]` mistake (section 41) is exactly the class of error that `validate` misses and only a plan against a cluster reveals.

**Limits and a way forward.** A fully automated check would start a kind cluster inside the CI job (kind runs fine on GitHub's runners), build and load the image, run `terraform apply`, curl `/health`, and destroy. That would take several minutes per run and was not added.

**Interview questions**
1. What is the difference between what `terraform validate` proves and what a successful `plan` proves?
2. Why is it useful to commit the dependency lock file with hashes for more than one platform?
3. How would you test a Terraform configuration that manages a Kubernetes cluster in CI without touching a real cluster?

---

# Phase 6: CI/CD (no cloud credentials, no paid services)

CI (continuous integration) checks every change; CD (continuous delivery/deployment) is the automated path that builds, publishes and deploys it. Everything here uses only GitHub's free runners, the free GitHub Container Registry (GHCR) and a throwaway kind cluster inside the runner; no cloud account is involved.

## 45. Hardening the workflow before adding delivery

**What changed.** Every `uses:` line is now pinned to a full commit SHA with the human-readable version in a trailing comment (for example `actions/checkout@3d3c42e... # v7.0.1`). Every job runs on `ubuntu-24.04` instead of `ubuntu-latest`. The actions were bumped to releases that run on Node 24 (I checked each action's `runs.using`; the earlier runs had shown a warning that Node 20 actions were being forced to Node 24). A `dependabot.yml` for the `github-actions` ecosystem keeps the pins current. The workflow-level `permissions: contents read` stays as the default; later jobs raise it only where needed.

**Why SHAs, not tags.** A tag such as `@v4` is a pointer the action's owner (or an attacker who compromises their account) can move to different code, and your next run would execute it, with whatever secrets and token permissions the job has. A commit SHA is immutable. That matters most for a job that can push images. The cost is readability and upkeep, which the version comment and Dependabot address.

**Why pin the runner.** `ubuntu-latest` silently changes under you; the earlier runs carried a notice that it moves to a new Ubuntu release on 2026-10-19. With `ubuntu-24.04` the change happens when I edit the file, not on a date I did not choose.

**Concurrency change.** The workflow used to cancel an older run whenever a newer push arrived. On `main` that could kill a publish halfway, so cancellation now applies only to non-`main` refs.

**Limits.** The major versions jumped (checkout v4 to v7, setup-python v5 to v7, setup-terraform v3 to v4, setup-tflint v4 to v6), so behaviour could differ; CI is what tells me. A pinned SHA protects the action's own code but not what that action downloads at run time (for example it fetches a Terraform or tflint binary). Dependabot only proposes updates; someone has to review them.

**Interview questions**
1. Why is pinning a GitHub Action to a commit SHA safer than pinning to a version tag, and what does it cost you?
2. What can a compromised third-party action do in a job, and how do job-level `permissions` limit the damage?
3. Why would you pin `runs-on` to a specific runner image instead of `ubuntu-latest`?

## 46. Scanning the image with Trivy

**What it is.** Trivy reads a container image, lists the operating-system packages and Python libraries inside it, and matches them against a database of known vulnerabilities (CVEs). `scripts/trivy-scan.sh <image>` does two things: it **reports** the CRITICAL and HIGH counts (total, with a fix available, and with no fix yet) as a table in the job summary, and it applies a **gate**: the script exits non-zero only if a CRITICAL vulnerability **with a fix available** exists. HIGH findings never fail the build.

**Real result (local run, Trivy 0.75.0, image built from the current code, Debian 13.7 base).** 0 CRITICAL and 44 HIGH. All 44 HIGH findings are in operating-system packages of the `python:3.12-slim` base image (util-linux and its libraries, ncurses, systemd libraries, perl-base), and **none has a fix available** (the Debian status is "affected" or "fix deferred"). None are in our Python dependencies. So the gate passes today, and there was nothing to ignore. These numbers will change from day to day because the vulnerability database is updated continuously; CI will report its own counts.

**Why gate only on "fixable CRITICAL".** A gate that fails on anything without a fix would block every build until a distribution ships a patch that we cannot influence, so people learn to ignore or disable it. Failing only when an update exists makes the failure actionable: bump the base image, rebuild. Findings without a fix stay visible in the summary so they are not forgotten.

**How I tested the gate (rather than assuming it works).** Default settings on the real image: exit 0. With the gate deliberately tightened (`TRIVY_GATE_SEVERITY=HIGH TRIVY_GATE_IGNORE_UNFIXED=false`) the same image fails with exit 1 and prints the findings. The "fix available" table is produced by a separate small script (`scripts/trivy_summary.py`); I checked it with a synthetic report containing one fixable CRITICAL. I found and fixed a bug on the way: the script exited 1 even when the gate passed, because its last command was `[ -n "$VAR" ] && ...`, which returns 1 when the variable is unset.

**`.trivyignore`.** It exists, with the policy written in it, and currently ignores nothing. Anything added must carry a reason and a review date.

**Limits.** Trivy only knows vulnerabilities in its database at scan time (a CVE published tomorrow is not caught today), and it scans the image's packages, not our application logic. "Fix available" depends on the distribution's data. The scan runs in CI before the image is pushed (next section) but not on a schedule, so an image already published can become vulnerable without anything alerting us.

**Interview questions**
1. Why does the gate fail only on CRITICAL vulnerabilities that have a fix, and what are the risks of that policy?
2. What is the difference between scanning an image and scanning the application's source dependencies?
3. A scan passes today and fails tomorrow on the same image. Why can that happen, and how would you handle it?

## 47. The publish job: build, scan, then push

**What it is.** A `publish` job builds the image, scans it with Trivy (section 46), logs in to GHCR with the built-in `GITHUB_TOKEN`, and pushes `ghcr.io/aadi1706/usageline:<commit SHA>`. GHCR is GitHub's container registry; it is free for this use and needs no extra account or stored secret.

**Decisions.**
- **Only on pushes to `main`, and only after the other five jobs succeed** (`if:` on the event and ref, plus `needs: [lint, test, docker, helm, terraform]`). Pull requests build and test but never publish, so an unreviewed change can never produce a registry image.
- **Scan before push.** The image is built into the runner's local Docker daemon first (`load: true`, `push: false`), scanned, and pushed only if the gate passes. A vulnerable image therefore never reaches the registry, instead of being published and then flagged afterwards.
- **Tagged with the commit SHA, not `latest`.** A SHA tag says exactly which code is in the image, can be traced back to a commit, and is what a deployment or rollback should reference. `latest` is a moving label that tells you nothing about what is running.
- **Minimal permissions.** The workflow default is read-only; only this job has `packages: write`. It authenticates with the per-run `GITHUB_TOKEN`, which expires when the run ends, so there is no long-lived credential to leak.
- **Labels.** `org.opencontainers.image.source` links the package to the repository (which is also how GHCR connects package permissions to the repo) and `revision` records the commit. The digest of the pushed image is written to the job summary.
- **Concurrency.** Runs on `main` are not cancelled (section 45), so a publish is not interrupted by the next push.

**Limits.** The image is not signed and has no SBOM or provenance attestation (tools such as cosign could add them). A SHA tag in a registry can still be overwritten by someone with write access; the **digest** is the truly immutable reference. A re-run of the same commit rebuilds and re-pushes the same tag, and the rebuilt image can differ slightly. Nothing stops a bad commit reaching `main` except the earlier jobs, because no branch protection or required reviews are configured here. New GHCR packages can start out private, which matters for who can pull them (see the next section for how the rehearsal job pulls it).

**Interview questions**
1. Why tag images with the commit SHA rather than `latest`, and what is the difference between a tag and a digest?
2. Why scan the image before pushing it instead of after?
3. What does `GITHUB_TOKEN` give you compared with a personal access token, and why restrict `packages: write` to one job?

## 48. Smoke test and the atomic-rollback rehearsal (scripts, tested locally first)

**What they are.** `scripts/smoke-test.sh` checks `/health` and `/ready`, then runs the real business flow: create a plan, a tenant, record 150 usage units, generate an invoice, read it back, and assert the arithmetic (150 units - 100 included = 50 billable x 5 cents + 1000 base = 1250). `scripts/deploy-rehearsal.sh` installs the chart with `helm upgrade --install --atomic --timeout 5m`, runs the smoke test, then performs a **deliberately broken upgrade** and checks that Helm rolls it back and the previous version keeps serving. Both are plain scripts rather than YAML so I could run them against a throwaway local kind cluster before CI ever saw them.

**What `--atomic` does.** Helm waits for the release's resources to become ready; if that does not happen within `--timeout`, an atomic upgrade rolls the release back to the previous revision automatically. (Helm 4 renamed the flag to `--rollback-on-failure`; `--atomic` still works there as a deprecated alias that prints a warning, which is what the scripts use.)

**The break I chose, and why.** A readiness probe on a path that does not exist (`--set probes.readiness.path=/does-not-exist`). The new pods start but never become Ready, so the rolling update stalls and Helm must decide. I deliberately did **not** use a nonexistent image tag: the chart runs database migrations as a `pre-upgrade` hook Job from the same image, so a bad tag would fail at that hook before the Deployment is ever touched, which proves much less than a rollout that starts and then fails.

**Local results (temporary kind cluster, locally built image; this is not the CI run).** The atomic install passed and the smoke test passed. The broken upgrade failed with Helm reporting the Deployment "not ready ... Updated: 1/2 ... context deadline exceeded", and Helm rolled back ("Rollback to 1"). With `--timeout 90s` the command returned after **96 s** (90 s of waiting plus about 6 s for the rollback); with a 45 s timeout it returned after 52 s. A probe of `/ready` every 0.5 s during the broken upgrade got HTTP 200 in all 184 attempts (and 101 of 101 in the second run); afterwards the live Deployment had the original image and the `/ready` probe path again, and the smoke test passed a second time.

**What the time means.** Helm does not detect that the new pods are bad quickly: it waits out the whole timeout, so the time to failure is about the timeout you set, plus the rollback. Your timeout is therefore the length of a failed deploy. A shorter one (90 s here, 5 m for the good deploy) bounds how long a bad release sits half-rolled-out.

**Why the old pods kept serving.** The default rolling-update settings (`maxUnavailable` 25% of 2 pods rounds down to 0, `maxSurge` 1) add one new pod before removing any old one. Since the new pod never became Ready, no old pod was ever removed, and Services only route to Ready pods. Without that, a bad release could take down the working one.

**Limits.** The probe measures one URL through one path on a kind cluster, not real traffic. The test needs the schema to be compatible between versions; a migration that already ran in the broken release is not undone by a Helm rollback (the bad release here had no migration). Rollback restores the previous *configuration*, not data.

**Interview questions**
1. What does `helm upgrade --atomic` do on failure, and how long does it take to notice a bad release? What controls that?
2. Why does a failing rolling update not cause downtime, and what Deployment settings make that true?
3. Why was a nonexistent image tag a weaker test of rollback than a failing readiness probe in this chart?
