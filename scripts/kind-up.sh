#!/usr/bin/env bash
# Create the kind cluster, build + load the image, install metrics-server and the Helm chart.
set -euo pipefail

CLUSTER=usageline
CONTEXT="kind-${CLUSTER}"
NAMESPACE=usageline
METRICS_SERVER_VERSION=v0.9.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for tool in docker kind kubectl helm; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

if kind get clusters | grep -qx "$CLUSTER"; then
  echo "==> kind cluster '$CLUSTER' already exists, reusing it"
else
  echo "==> creating kind cluster '$CLUSTER'"
  kind create cluster --config "$ROOT/kind/cluster.yaml"
fi

echo "==> building image"
IMAGE_ID="$(docker build -q "$ROOT")"
TAG="${IMAGE_ID#sha256:}"
TAG="${TAG:0:12}"
docker tag "$IMAGE_ID" "usageline:${TAG}"

echo "==> loading usageline:${TAG} into kind"
kind load docker-image "usageline:${TAG}" --name "$CLUSTER"

echo "==> installing metrics-server ${METRICS_SERVER_VERSION}"
kubectl --context "$CONTEXT" apply -f \
  "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# kind's kubelet serves a self-signed certificate, so metrics-server must skip TLS verification.
if ! kubectl --context "$CONTEXT" -n kube-system get deploy metrics-server \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls; then
  kubectl --context "$CONTEXT" -n kube-system patch deployment metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl --context "$CONTEXT" -n kube-system rollout status deployment/metrics-server --timeout=120s

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
  --wait --timeout 300s

echo
echo "Ready. API: http://localhost:8081  (try: curl localhost:8081/health ; curl localhost:8081/ready)"
