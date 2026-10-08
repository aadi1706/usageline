#!/usr/bin/env bash
# End-to-end smoke test against a running API. Usage: smoke-test.sh [base-url]
# Checks /health and /ready, then runs the real flow: create plan, create tenant, record usage, generate an
# invoice and read it back, asserting the billing arithmetic.
set -euo pipefail

BASE_URL="${1:-http://localhost:8081}"
SUFFIX="$(date +%s)-$RANDOM"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
field() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
call() { # method path [json-body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS --max-time 10 -X "$method" -H 'Content-Type: application/json' -d "$body" "$BASE_URL$path"
  else
    curl -fsS --max-time 10 -X "$method" "$BASE_URL$path"
  fi
}

echo "==> waiting for $BASE_URL/health"
for _ in $(seq 1 30); do
  curl -fsS --max-time 3 "$BASE_URL/health" >/dev/null 2>&1 && break
  sleep 2
done

[ "$(call GET /health | field status)" = "ok" ] || fail "/health did not return status ok"
echo "ok   /health"
[ "$(call GET /ready | field status)" = "ready" ] || fail "/ready did not return status ready"
echo "ok   /ready"

PLAN_ID="$(call POST /plans "{\"name\":\"smoke-$SUFFIX\",\"base_fee_cents\":1000,\"included_units\":100,\"unit_price_cents\":5}" | field id)"
echo "ok   created plan $PLAN_ID"
TENANT_ID="$(call POST /tenants "{\"name\":\"smoke-$SUFFIX\",\"plan_id\":$PLAN_ID}" | field id)"
echo "ok   created tenant $TENANT_ID"
call POST "/tenants/$TENANT_ID/usage" '{"metric":"api_calls","quantity":150}' >/dev/null
echo "ok   recorded 150 usage units"
INVOICE="$(call POST "/tenants/$TENANT_ID/invoices" '{"period_start":"2020-01-01T00:00:00Z","period_end":"2100-01-01T00:00:00Z"}')"
INVOICE_ID="$(echo "$INVOICE" | field id)"
echo "ok   generated invoice $INVOICE_ID"

READ="$(call GET "/invoices/$INVOICE_ID")"
# 150 units - 100 included = 50 billable x 5 cents = 250, plus the 1000 cent base fee = 1250.
[ "$(echo "$READ" | field total_units)" = "150" ] || fail "invoice total_units is not 150: $READ"
[ "$(echo "$READ" | field total_cents)" = "1250" ] || fail "invoice total_cents is not 1250: $READ"
echo "ok   invoice read back: 150 units, total 1250 cents"
echo "SMOKE PASSED"
