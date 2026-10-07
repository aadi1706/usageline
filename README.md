# Usageline

[![CI](https://github.com/aadi1706/usageline/actions/workflows/ci.yml/badge.svg)](https://github.com/aadi1706/usageline/actions/workflows/ci.yml)

Usageline is a multi-tenant usage-based billing platform. Tenants subscribe to plans (a base fee, a number of included units and a per-unit overage price), report usage events, and an endpoint turns a billing period's usage into an invoice. The app is deliberately small (FastAPI + PostgreSQL); the focus of the project is the infrastructure around it: containers, Kubernetes with kind, Helm, Terraform, GitHub Actions and Prometheus/Grafana, all runnable locally for free.

## Run it

Requires Docker with Compose.

```bash
docker compose up --build -d
curl http://localhost:8001/health
```

- API: http://localhost:8001 (interactive docs at `/docs`)
- Postgres: `localhost:5433` (user/password/db: `usageline`)

Migrations run automatically when the API container starts. Stop with `docker compose down` (add `-v` to also delete the database volume).

### Example

```bash
curl -X POST localhost:8001/plans -H 'content-type: application/json' \
  -d '{"name":"starter","base_fee_cents":1000,"included_units":100,"unit_price_cents":5}'
curl -X POST localhost:8001/tenants -H 'content-type: application/json' \
  -d '{"name":"acme","plan_id":1}'
curl -X POST localhost:8001/tenants/1/usage -H 'content-type: application/json' \
  -d '{"metric":"api_calls","quantity":150}'
curl -X POST localhost:8001/tenants/1/invoices -H 'content-type: application/json' \
  -d '{"period_start":"2026-01-01T00:00:00Z","period_end":"2027-01-01T00:00:00Z"}'
```

## Run the tests

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest
```

Tests use in-memory SQLite by default; set `TEST_DATABASE_URL` to run them against Postgres.

## API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Liveness check |
| POST/GET | `/plans` | Create / list plans |
| POST/GET | `/tenants`, GET `/tenants/{id}` | Create / list / fetch tenants |
| POST/GET | `/tenants/{id}/usage` | Record / list usage events |
| POST/GET | `/tenants/{id}/invoices` | Generate / list invoices |
| GET | `/invoices/{id}` | Fetch an invoice |

Invoice = plan base fee + max(0, units used in `[period_start, period_end)` - included units) x unit price. Amounts are integer cents.
