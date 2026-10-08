#!/usr/bin/env bash
# Everything the Helm releases need that Terraform does not model: the kind cluster, the loaded image and
# metrics-server. Installs NO Helm releases. Progress goes to stderr; the loaded image tag is printed to stdout.
set -euo pipefail
exec 3>&1 1>&2

CLUSTER=usageline
CONTEXT="kind-${CLUSTER}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for tool in docker kind kubectl; do
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

echo "==> installing metrics-server"
"$ROOT/scripts/install-metrics-server.sh" "$CONTEXT"

echo "==> bootstrap done. Image tag: ${TAG}  (terraform: -var image_tag=${TAG})"
echo "$TAG" >&3
