#!/usr/bin/env bash
# Install kube-prometheus-stack into the "monitoring" namespace, then redeploy usageline so its
# ServiceMonitor, alert rules and Grafana dashboard are enabled. Requires the kind cluster (kind-up.sh).
set -euo pipefail

CLUSTER=usageline
CONTEXT="kind-${CLUSTER}"
CHART_VERSION=92.1.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for tool in kind kubectl helm; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done
kind get clusters | grep -qx "$CLUSTER" || { echo "kind cluster '$CLUSTER' not found, run scripts/kind-up.sh first" >&2; exit 1; }

echo "==> adding prometheus-community helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

echo "==> installing kube-prometheus-stack ${CHART_VERSION} into 'monitoring'"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version "$CHART_VERSION" \
  --kube-context "$CONTEXT" \
  --namespace monitoring --create-namespace \
  -f "$ROOT/monitoring/values.yaml" \
  --wait --timeout 400s

echo "==> redeploying usageline with monitoring enabled"
"$ROOT/scripts/kind-up.sh"

cat <<MSG

Monitoring is up. Port-forward (each in its own terminal):

  Grafana     kubectl --context ${CONTEXT} -n monitoring port-forward svc/kps-grafana 3000:80
              http://localhost:3000   (user: admin, password: admin)
  Prometheus  kubectl --context ${CONTEXT} -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
              http://localhost:9090
  Alertmanager kubectl --context ${CONTEXT} -n monitoring port-forward svc/kps-kube-prometheus-stack-alertmanager 9093:9093

Dashboard: Grafana -> Dashboards -> "Usageline API". Load test: k6 run loadtest/k6.js
MSG
