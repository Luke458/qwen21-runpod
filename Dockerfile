# Qwen-Image 2.1 + ComfyUI — prebuilt RunPod image.
#
# Bakes a pinned ComfyUI (Qwen-Image 2.1 support + the training dataset detach
# fix) onto the CUDA 12.8 / torch 2.9.1 RunPod base. Model weights are NOT baked
# in: they download to the network volume on first boot (~26 GB).
#
# Build (no GPU needed on the build host):
#   ./build-and-push.sh
FROM docker.io/runpod/pytorch:1.3.2-cu1281-torch291-ubuntu2204

ARG COMFYUI_REPO=https://github.com/comfyanonymous/ComfyUI.git
ARG COMFYUI_REF=5ba116a40f1944f64e2e4a8ace826656e6293bf4

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONNOUSERSITE=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    COMFYUI_DIR=/opt/ComfyUI

# git/patch for the pinned checkout and the training fix, ffmpeg + GL/GLib for
# image/video nodes, rsync so a volume from an older image can be refreshed.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git patch rsync ffmpeg \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
        ca-certificates curl wget \
    && rm -rf /var/lib/apt/lists/*

COPY patches/ /opt/qwen21/patches/

RUN git clone "${COMFYUI_REPO}" "${COMFYUI_DIR}" \
    && git -C "${COMFYUI_DIR}" checkout "${COMFYUI_REF}" \
    && git -C "${COMFYUI_DIR}" apply /opt/qwen21/patches/*.patch \
    && rm -rf "${COMFYUI_DIR}/.git"

WORKDIR ${COMFYUI_DIR}

# Base image already provides torch/torchvision/torchaudio for CUDA 12.8.
RUN python -m pip install --no-cache-dir --upgrade pip wheel setuptools \
    && python -m pip install --no-cache-dir -r requirements.txt \
    && python -m pip install --no-cache-dir -r manager_requirements.txt \
    && python -m pip install --no-cache-dir "huggingface_hub[cli]" hf_transfer

# Prove the pinned source is the patched one and that CUDA torch imports.
RUN python -m py_compile comfy_extras/nodes_dataset.py \
    && grep -q "_detach_conditioning" comfy_extras/nodes_dataset.py \
    && python -c "import torch; print('torch', torch.__version__, '| cuda', torch.version.cuda)"

COPY workflows/ /opt/qwen21/workflows/
COPY runpod-setup.sh /opt/qwen21/setup.sh

# First-boot helper: materialize ComfyUI on the network volume, then run the
# idempotent setup (weights download once, workflows + start script installed).
RUN printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'COMFY_DIR=/workspace/ComfyUI' \
    'if [[ ! -d "$COMFY_DIR" ]]; then' \
    '  cp -a /opt/ComfyUI "$COMFY_DIR"' \
    'fi' \
    'exec bash /opt/qwen21/setup.sh' \
    > /usr/local/bin/qwen21-init \
    && chmod +x /usr/local/bin/qwen21-init

WORKDIR /workspace
