#!/usr/bin/env bash
# Create the kind cluster, build + load the image, install metrics-server and the Helm chart.
set -euo pipefail

CLUSTER=usageline
CONTEXT="kind-${CLUSTER}"
NAMESPACE=usageline
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for tool in docker kind kubectl helm; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

# Cluster, image and metrics-server live in kind-bootstrap.sh (shared with the Terraform workflow, see
# terraform/envs/local); it prints the loaded image tag as its only stdout.
TAG="$("$ROOT/scripts/kind-bootstrap.sh")"

# ServiceMonitor/PrometheusRule need the Prometheus Operator CRDs; only enable them once monitoring-up.sh installed them.
EXTRA_VALUES=()
if kubectl --context "$CONTEXT" get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  echo "==> Prometheus Operator CRDs found, enabling ServiceMonitor, alerts and dashboard"
  EXTRA_VALUES=(-f "$ROOT/monitoring/usageline-values.yaml")
fi

echo "==> helm upgrade --install"
helm upgrade --install usageline "$ROOT/helm/usageline" \
  --kube-context "$CONTEXT" \
  ${EXTRA_VALUES[@]+"${EXTRA_VALUES[@]}"} \
  --namespace "$NAMESPACE" --create-namespace \
  --set image.tag="$TAG" \
  --force-conflicts \
  --wait --timeout 300s

echo
echo "Ready. API: http://localhost:8081  (try: curl localhost:8081/health ; curl localhost:8081/ready)"
