#!/usr/bin/env bash
# Scan a container image with Trivy. Usage: trivy-scan.sh <image>
#  1. Reports CRITICAL and HIGH counts (total and "fix available") and writes them to the GitHub job summary.
#  2. Fails (exit 1) if any CRITICAL vulnerability has a fix available. HIGH never fails the build.
# Anything ignored must be listed with a reason in .trivyignore (Trivy reads it from the repo root).
# Env: TRIVY_GATE_SEVERITY (default CRITICAL), TRIVY_GATE_IGNORE_UNFIXED (default true), used to test the gate.
set -euo pipefail

IMAGE="${1:?usage: trivy-scan.sh <image>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE_SEVERITY="${TRIVY_GATE_SEVERITY:-CRITICAL}"
GATE_IGNORE_UNFIXED="${TRIVY_GATE_IGNORE_UNFIXED:-true}"
OUT="$(mktemp -d)"
IGNOREFILE="$ROOT/.trivyignore"

trivy image --quiet --format json --severity CRITICAL,HIGH --ignorefile "$IGNOREFILE" \
  --output "$OUT/report.json" "$IMAGE"

python3 "$ROOT/scripts/trivy_summary.py" "$OUT/report.json" "$IMAGE" | tee "$OUT/summary.md"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"
fi

echo
echo "==> Gate: fail on ${GATE_SEVERITY} (ignore unfixed: ${GATE_IGNORE_UNFIXED})"
GATE_ARGS=(--quiet --severity "$GATE_SEVERITY" --exit-code 1 --ignorefile "$IGNOREFILE")
if [ "$GATE_IGNORE_UNFIXED" = "true" ]; then GATE_ARGS+=(--ignore-unfixed); fi
if trivy image "${GATE_ARGS[@]}" "$IMAGE" >"$OUT/gate.txt"; then
  echo "Gate passed."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '\n**Gate passed:** no %s vulnerability with a fix available.\n' "$GATE_SEVERITY" >> "$GITHUB_STEP_SUMMARY"
  fi
else
  cat "$OUT/gate.txt"
  echo "Gate FAILED: ${GATE_SEVERITY} vulnerabilities with a fix available (see above)." >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '\n**Gate FAILED:** %s vulnerabilities with a fix available.\n' "$GATE_SEVERITY" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi
