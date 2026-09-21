#!/usr/bin/env bash
#
# Build the Qwen-Image 2.1 + ComfyUI RunPod image and push it to a registry.
#
# No GPU is required on this machine. Podman or Docker both work.
#
# Set your registry first, e.g.:
#   export REGISTRY=ghcr.io/<your-github-user>
#   export REGISTRY=docker.io/<your-dockerhub-user>
#
# Then:
#   ./build-and-push.sh              # build + push
#   ./build-and-push.sh --no-push    # build only
#
# Env overrides:
#   IMAGE_NAME=qwen21-runpod   TAG=cu128-torch260
set -euo pipefail

cd "$(dirname "$0")"

IMAGE_NAME="${IMAGE_NAME:-qwen21-runpod}"
TAG="${TAG:-cu128-torch260}"

DO_PUSH=1
[[ "${1:-}" == "--no-push" ]] && DO_PUSH=0

: "${REGISTRY:?Set REGISTRY first, e.g. export REGISTRY=ghcr.io/<user>}"
FULL_IMAGE="${REGISTRY%/}/${IMAGE_NAME}:${TAG}"

# Pick a container engine (docker may be podman under the hood).
if command -v docker >/dev/null 2>&1; then ENGINE=docker
elif command -v podman >/dev/null 2>&1; then ENGINE=podman
else echo "No docker or podman found." >&2; exit 1; fi
echo "Engine: ${ENGINE}"

echo "Building ${FULL_IMAGE}"
echo "Typically ~3-5 min: the base image provides torch, then ComfyUI's"
echo "requirements plus the pinned checkout are installed."

"${ENGINE}" build \
  --platform linux/amd64 \
  -t "${FULL_IMAGE}" \
  .

if (( DO_PUSH )); then
  echo "Pushing ${FULL_IMAGE}"
  "${ENGINE}" push "${FULL_IMAGE}"
  echo
  echo "Push complete. Register it as a RunPod template:"
  echo "  IMAGE=${FULL_IMAGE} TEMPLATE_NAME=qwen21 ./runpod-pod.sh template"
  echo "Then boot a Pod from it:"
  echo "  TEMPLATE_ID=<id> ./runpod-pod.sh up 4090"
else
  echo "Built ${FULL_IMAGE} (not pushed)."
fi
