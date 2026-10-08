#!/usr/bin/env bash
# Deploy rehearsal on a kind cluster: atomic install + smoke test, then a deliberately broken upgrade to prove
# that --atomic rolls back and the previous version keeps serving. Writes a markdown report to
# $GITHUB_STEP_SUMMARY when set. Expects the image to already be available to the cluster (kind load).
#
# Env: IMAGE_REPOSITORY, IMAGE_TAG (required); KUBE_CONTEXT (kind-usageline), NAMESPACE/RELEASE (usageline),
#      BASE_URL (http://localhost:8081), PORT_FORWARD=1 to reach the service through kubectl port-forward,
#      DEPLOY_TIMEOUT (5m), BROKEN_TIMEOUT (90s), HELM_EXTRA_ARGS (extra helm flags, word-split).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTX="${KUBE_CONTEXT:-kind-usageline}"
NS="${NAMESPACE:-usageline}"
REL="${RELEASE:-usageline}"
REPO="${IMAGE_REPOSITORY:?set IMAGE_REPOSITORY}"
TAG="${IMAGE_TAG:?set IMAGE_TAG}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-5m}"
BROKEN_TIMEOUT="${BROKEN_TIMEOUT:-90s}"
BASE_URL="${BASE_URL:-http://localhost:8081}"
# shellcheck disable=SC2206
HELM_EXTRA=(${HELM_EXTRA_ARGS:-})
WORK="$(mktemp -d)"
PIDS=()

k() { kubectl --context "$CTX" -n "$NS" "$@"; }
now() { date +%s; }
report() { # append a line to the console and the job summary
  echo "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

HELM_ARGS=("$ROOT/helm/usageline" --kube-context "$CTX" --namespace "$NS"
  --set "image.repository=$REPO" --set "image.tag=$TAG" ${HELM_EXTRA[@]+"${HELM_EXTRA[@]}"})

# ---------- 1. atomic install of the good version ----------
echo "==> helm upgrade --install --atomic (good version $REPO:$TAG)"
T0=$(now)
helm upgrade --install "$REL" "${HELM_ARGS[@]}" --create-namespace --atomic --timeout "$DEPLOY_TIMEOUT"
DEPLOY_SECS=$(( $(now) - T0 ))
GOOD_REVISION="$(helm --kube-context "$CTX" -n "$NS" history "$REL" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["revision"])')"

if [ "${PORT_FORWARD:-0}" = "1" ]; then
  kubectl --context "$CTX" -n "$NS" port-forward "svc/$REL" 18081:80 >/dev/null 2>&1 &
  PIDS+=("$!")
  BASE_URL="http://localhost:18081"
  sleep 3
fi

# ---------- 2. smoke test ----------
echo "==> smoke test (good version)"
"$ROOT/scripts/smoke-test.sh" "$BASE_URL"

# ---------- 3. deliberately broken upgrade ----------
# The break is a readiness probe that can never pass. The migration hook Job uses the same image and still
# succeeds, so the Deployment rollout itself is what fails: new pods never become Ready, so Helm must roll back.
# (A nonexistent image tag would instead fail at the pre-upgrade migration hook, before the Deployment is
# touched, which proves much less.)
echo "==> starting availability probe against $BASE_URL/ready (every 0.5s)"
PROBE_FILE="$WORK/probe.txt"
: > "$PROBE_FILE"
(
  while true; do
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 2 "$BASE_URL/ready" >> "$PROBE_FILE" 2>/dev/null || echo 000 >> "$PROBE_FILE"
    sleep 0.5
  done
) &
PROBE_PID=$!
PIDS+=("$PROBE_PID")

echo "==> helm upgrade --atomic --timeout $BROKEN_TIMEOUT with a broken readiness probe (expected to FAIL and roll back)"
T1=$(now)
set +e
helm upgrade "$REL" "${HELM_ARGS[@]}" --atomic --timeout "$BROKEN_TIMEOUT" \
  --set probes.readiness.path=/does-not-exist >"$WORK/broken.log" 2>&1
BROKEN_RC=$?
set -e
BROKEN_SECS=$(( $(now) - T1 ))
echo "---- helm output (last lines) ----"; tail -n 8 "$WORK/broken.log"; echo "----------------------------------"

sleep 2
kill "$PROBE_PID" 2>/dev/null || true
wait "$PROBE_PID" 2>/dev/null || true
TOTAL_PROBES=$(wc -l < "$PROBE_FILE" | tr -d ' ')
BAD_PROBES=$(grep -vc '^200$' "$PROBE_FILE" || true)

# ---------- 4. verify the rollback ----------
FAILURES=()
[ "$BROKEN_RC" -ne 0 ] || FAILURES+=("the broken upgrade unexpectedly SUCCEEDED")
HISTORY="$(helm --kube-context "$CTX" -n "$NS" history "$REL" -o json)"
LAST_STATUS="$(echo "$HISTORY" | python3 -c 'import json,sys; h=json.load(sys.stdin)[-1]; print(h["status"], "|", h["description"])')"
LIVE_PROBE="$(k get deploy "$REL" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}')"
LIVE_IMAGE="$(k get deploy "$REL" -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "$LIVE_PROBE" = "/ready" ] || FAILURES+=("live readiness path is $LIVE_PROBE, expected /ready")
[ "$LIVE_IMAGE" = "$REPO:$TAG" ] || FAILURES+=("live image is $LIVE_IMAGE, expected $REPO:$TAG")
k rollout status "deploy/$REL" --timeout=120s || FAILURES+=("deployment is not fully rolled out after rollback")
[ "$BAD_PROBES" -eq 0 ] || FAILURES+=("$BAD_PROBES of $TOTAL_PROBES availability probes failed during the broken upgrade")
"$ROOT/scripts/smoke-test.sh" "$BASE_URL" || FAILURES+=("smoke test failed after rollback")

# ---------- 5. report ----------
report ""
report "### Deploy rehearsal"
report ""
report "| Step | Result |"
report "| --- | --- |"
report "| Atomic install of \`$REPO:$TAG\` | succeeded in ${DEPLOY_SECS}s (release revision $GOOD_REVISION) |"
report "| Smoke test (health, ready, create tenant, record usage, generate and read invoice) | passed |"
report "| Broken upgrade (readiness probe \`/does-not-exist\`, \`--atomic --timeout $BROKEN_TIMEOUT\`) | helm exit code $BROKEN_RC, returned after **${BROKEN_SECS}s** (includes waiting out the timeout and the rollback) |"
report "| Availability during the broken upgrade | $((TOTAL_PROBES - BAD_PROBES)) of $TOTAL_PROBES probes of \`/ready\` returned 200 |"
report "| Release after rollback | $LAST_STATUS |"
report "| Live version after rollback | image \`$LIVE_IMAGE\`, readiness path \`$LIVE_PROBE\` |"
report ""
if [ "${#FAILURES[@]}" -gt 0 ]; then
  report "**Rehearsal FAILED:**"
  for f in "${FAILURES[@]}"; do report "- $f"; done
  exit 1
fi
report "**Rehearsal passed:** the broken release was rolled back automatically and the previous version kept serving."
