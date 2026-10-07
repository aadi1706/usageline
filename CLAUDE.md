# Usageline

Multi-tenant usage-based billing platform. This is a portfolio project for a Cloud Engineer internship at Chargebee, where infrastructure quality matters more than app complexity.

## Stack

- App: FastAPI, PostgreSQL (SQLAlchemy + Alembic)
- Packaging/runtime: Docker, Kubernetes with kind, Helm
- Infrastructure as code: Terraform
- CI/CD: GitHub Actions
- Observability: Prometheus, Grafana

## Rules

- Keep the app simple: tenants, plans, usage events, invoices.
- Everything must run locally for free.
- Every feature gets a test.
- Small commits.
- Never invent benchmark numbers. Only report numbers that were actually measured.
- Host ports: API on 8001, Postgres on 5433. Ports 8000 and 6333 are used by other containers (nbfc_backend, nbfc_qdrant).
- Never stop, remove or modify existing Docker containers.
