#!/usr/bin/env bash
# Install metrics-server on a kind cluster. Usage: install-metrics-server.sh [kube-context]
set -euo pipefail

CONTEXT="${1:-kind-usageline}"
METRICS_SERVER_VERSION=v0.9.0

kubectl --context "$CONTEXT" apply -f \
  "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# kind's kubelet serves a self-signed certificate, so metrics-server must skip TLS verification.
if ! kubectl --context "$CONTEXT" -n kube-system get deploy metrics-server \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls; then
  kubectl --context "$CONTEXT" -n kube-system patch deployment metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl --context "$CONTEXT" -n kube-system rollout status deployment/metrics-server --timeout=120s
