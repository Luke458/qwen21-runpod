#!/usr/bin/env bash
#
# Upload the 512px identity training set to a running Qwen-Image 2.1 pod.
#
# Usage:
#   ./push-dataset.sh            # uses .last_pod_id
#   ./push-dataset.sh <podId>
#
# Env overrides:
#   SRC=/home/luke/Projects/ComfyUI/input/identity_lora_dataset2_face512
#   DEST=/workspace/ComfyUI/input
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="https://rest.runpod.io/v1"

SRC="${SRC:-/home/luke/Projects/ComfyUI/input/identity_lora_dataset2_face512}"
DEST="${DEST:-/workspace/ComfyUI/input}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

[[ -d "${SRC}" ]] || die "Dataset directory not found: ${SRC}"
command -v jq >/dev/null || die "jq is required"

if [[ -z "${RUNPOD_API_KEY:-}" && -f "${SCRIPT_DIR}/.env" ]]; then
  RUNPOD_API_KEY="$(sed -n 's/^[[:space:]]*\(RUNPOD_API_KEY\|runpod_api\)[[:space:]]*=[[:space:]]*//p' "${SCRIPT_DIR}/.env" \
    | head -1 | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
fi
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY or put it in .env}"

POD_ID="${1:-$(cat "${SCRIPT_DIR}/.last_pod_id" 2>/dev/null || true)}"
[[ -n "${POD_ID}" ]] || die "No pod id given and .last_pod_id is missing."

log "Resolving SSH for pod ${POD_ID}"
pod_json="$(curl -sS "${API}/pods/${POD_ID}" -H "Authorization: Bearer ${RUNPOD_API_KEY}")"
IP="$(jq -r '.publicIp // empty' <<<"${pod_json}")"
PORT="$(jq -r '.portMappings["22"] // empty' <<<"${pod_json}")"
[[ -n "${IP}" && -n "${PORT}" ]] || die "Pod has no SSH mapping yet. Is it running?"

TARBALL="$(mktemp -t qwen21-dataset-XXXXXX.tgz)"
trap 'rm -f "${TARBALL}"' EXIT

log "Packing $(basename "${SRC}")"
tar -C "$(dirname "${SRC}")" -czf "${TARBALL}" "$(basename "${SRC}")"
du -h "${TARBALL}" | awk '{print "  archive size:", $1}'

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -p "${PORT}")
SCP_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -P "${PORT}")
log "Uploading to root@${IP}:${DEST}"
scp "${SCP_OPTS[@]}" "${TARBALL}" "root@${IP}:/tmp/qwen21-dataset.tgz"
ssh -n "${SSH_OPTS[@]}" "root@${IP}" \
  "mkdir -p '${DEST}' && tar -xzf /tmp/qwen21-dataset.tgz -C '${DEST}' && rm -f /tmp/qwen21-dataset.tgz && ls '${DEST}/$(basename "${SRC}")' | wc -l"

log "Done. The folder '$(basename "${SRC}")' is now in ${DEST}."
