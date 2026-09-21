#!/usr/bin/env bash
#
# Qwen-Image 2.1 + ComfyUI — one-shot setup for a RunPod GPU pod.
#
# Run this ON THE POD (web terminal or SSH), not on your local machine:
#     bash /opt/qwen21/setup.sh
#
# The baked image provides the pinned ComfyUI source; this script materializes
# it on the network volume, applies the training dataset patch if needed,
# downloads the Qwen-Image 2.1 weights, and installs run scripts. It is
# idempotent: re-running skips completed steps.
set -euo pipefail

COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
MODELS_DIR="${MODELS_DIR:-${COMFY_DIR}/models}"
export HF_HOME="${HF_HOME:-/workspace/hf}"
export HF_HUB_ENABLE_HF_TRANSFER=1

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- sanity ----
log "Checking environment"
command -v nvidia-smi >/dev/null || die "nvidia-smi not found — this must run on a GPU pod."
nvidia-smi -L || die "No GPU detected by driver."
python - <<'PY'
import torch
print(f"torch {torch.__version__} | cuda {torch.version.cuda} | available {torch.cuda.is_available()}")
assert torch.cuda.is_available(), "torch cannot see the GPU"
PY

# ------------------------------------------------------------------ code ----
mkdir -p "${COMFY_DIR}"
if [[ ! -f "${COMFY_DIR}/main.py" ]]; then
  log "Materializing ComfyUI into ${COMFY_DIR}"
  cp -a /opt/ComfyUI/. "${COMFY_DIR}/"
else
  log "Refreshing ComfyUI code from the image (models/user/output kept)"
  rsync -a --delete \
    --exclude 'models' --exclude 'input' --exclude 'output' \
    --exclude 'user' --exclude 'custom_nodes' --exclude 'temp' \
    /opt/ComfyUI/ "${COMFY_DIR}/"
fi

if ! grep -q "_detach_conditioning" "${COMFY_DIR}/comfy_extras/nodes_dataset.py"; then
  log "Applying training dataset detach patch"
  (cd "${COMFY_DIR}" && patch -p1 < /opt/qwen21/patches/dataset-detach.patch) \
    || die "Could not apply the dataset patch; training would fail at the second optimizer step."
fi

# ---------------------------------------------------------------- models ----
log "Downloading weights (~26 GB, resumes if interrupted)"
mkdir -p "${MODELS_DIR}"
HF_TOKEN="${HF_TOKEN:-}"  # optional; avoids anonymous rate limits
hf download Comfy-Org/Qwen-Image-2.1 \
    diffusion_models/qwen_image_2.1_bf16.safetensors \
    vae/qwen_image_2.1_vae_bf16.safetensors \
    --local-dir "${MODELS_DIR}" \
  || die "DiT/VAE download failed."
hf download Comfy-Org/Qwen3-VL \
    text_encoders/qwen3vl_8b_fp8_scaled.safetensors \
    --local-dir "${MODELS_DIR}" \
  || die "Text encoder download failed."

# ------------------------------------------------------------- run files ----
log "Installing workflows and run scripts"
mkdir -p "${COMFY_DIR}/user/default/workflows"
cp /opt/qwen21/workflows/*.json "${COMFY_DIR}/user/default/workflows/"

cat > /workspace/start-comfyui.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd /workspace/ComfyUI
exec python main.py --listen 0.0.0.0 --port 8188 --enable-manager "$@"
EOF
chmod +x /workspace/start-comfyui.sh

cat > /workspace/train-identity.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
COMFY_URL="${COMFY_URL:-http://127.0.0.1:8188}"
WORKFLOW="${WORKFLOW:-/workspace/ComfyUI/user/default/workflows/qwen_image_2.1_identity_train.json}"
curl -sS -X POST "${COMFY_URL}/prompt" \
  -H 'Content-Type: application/json' \
  --data-binary "@${WORKFLOW}" | tee /workspace/train-submit.json
echo
echo "Submitted. Watch progress in the ComfyUI UI (port 8188) or the pod log."
EOF
chmod +x /workspace/train-identity.sh

log "Done."
cat <<'EOF'
Next:
  1. Upload the 512px identity dataset from your machine:  ./push-dataset.sh
  2. Start ComfyUI:                                       ./start-comfyui.sh
  3. Train (ComfyUI must be running):                     ./train-identity.sh
     The LoRA lands in ComfyUI/output/loras/identity/.
EOF
