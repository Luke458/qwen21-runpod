# Qwen-Image 2.1 + ComfyUI on RunPod

Tooling to run **Qwen-Image 2.1 on ComfyUI** on rented RunPod GPUs, including
**identity LoRA training** from a folder of captioned face crops.

Written for a machine whose local GPU is a 16 GB AMD card: the Qwen-Image 2.1
weights do not fit there for training (ComfyUI dequantizes the int8 checkpoint
to ~14.5 GB bf16 before backprop), and the checkpointed path hits a PyTorch
autograd bug. A rented 24 GB+ NVIDIA GPU with the bf16 checkpoint and no
gradient checkpointing avoids both problems.

## Status (2026-09-21)

The image, pod tooling, weight download, and dataset upload all work, but
**training currently fails on ComfyUI's native trainer**: the second optimizer
iteration dies with `RuntimeError: Trying to backward through the graph a
second time`. This was reproduced on an L40S with the bf16 checkpoint, no
gradient checkpointing, no offloading, `bypass_mode` both on and off, and
gradient accumulation 1. The dataset detach patch fixes the encoding stage
(the error then points at an `AddcmulBackward0` node from the model's gated
residuals), so something upstream of the trainer reuses graph state across
iterations. Revisit once ComfyUI or musubi-tuner has a working training recipe
for this model; the image and setup can be reused as-is.

There is an official `runpod/comfyui` image, but it does not pin a ComfyUI
version and does not carry the dataset fix this training path needs, so this
repo mirrors `editalive-runpod` with its own pinned image.

## Contents

| File | Purpose |
|---|---|
| `Dockerfile` | Pinned ComfyUI (v0.36.0, commit `5ba116a4`) on `runpod/pytorch:1.3.2-cu1281-torch291`, with the dataset patch applied and requirements + ComfyUI-Manager installed. |
| `patches/dataset-detach.patch` | Makes `MakeTrainingDataset` return detached latents/conditioning. Without it the trainer fails on the second optimizer step with *"Trying to backward through the graph a second time"*. |
| `runpod-setup.sh` | On-pod, idempotent: materializes ComfyUI on `/workspace`, downloads weights, installs workflows and run scripts. |
| `runpod-pod.sh` | Create/manage pods and register templates via the RunPod REST API (same interface as `editalive-runpod`). |
| `build-and-push.sh` | Build and push the image locally (docker/podman; no GPU required). |
| `push-dataset.sh` | Upload `input/identity_lora_dataset2_face512` to a running pod. |
| `workflows/*.json` | API-format graphs: identity LoRA training and a text-to-image test with the trained LoRA. |
| `.github/workflows/build-image.yml` | CI that builds and pushes the image to GHCR. |

## Requirements

- RunPod account and [API key](https://www.runpod.io/console/user/settings).
- `jq`, `curl`, `ssh`, `scp`, `tar` locally.
- Optional: `docker` or `podman` if you build the image yourself.
- A GPU pod with **≥24 GB VRAM** (RTX 4090, L40S, A6000, A100). The bf16 DiT is
  ~14.5 GB and training needs activations on top; 48 GB is comfortable.

> **Security:** never commit your RunPod API key. `runpod-pod.sh` reads
> `RUNPOD_API_KEY` or a gitignored `.env` (accepting `RUNPOD_API_KEY` or
> `runpod_api`). Keep `.env` at `chmod 600`.

## Quick start

### 1. Build and push the image

Locally:

```bash
export REGISTRY=ghcr.io/<your-github-user>
./build-and-push.sh
```

Or push to GitHub and run the `Build Qwen-Image 2.1 ComfyUI image` workflow;
make the GHCR package public afterwards so RunPod can pull it.

### 1a. Package visibility

RunPod must be able to pull the image. If the GHCR package is public, no
credentials are needed. If it stays private (the default), either make it
public (profile → Packages → `qwen21-runpod` → Package settings → Change
visibility → Public) or add a RunPod registry credential and pass
`containerRegistryAuthId` when creating the template.

### 2. Register the template and boot a pod

```bash
export RUNPOD_API_KEY=...
cd qwen21-runpod
IMAGE=${REGISTRY}/qwen21-runpod:cu128-torch260 ./runpod-pod.sh template
TEMPLATE_ID=<id> ./runpod-pod.sh up 4090
```

`up` waits for SSH and starts `qwen21-init` in the background; watch it with
`tail -f /workspace/init.log`. First boot downloads ~26 GB of weights:

- `diffusion_models/qwen_image_2.1_bf16.safetensors` (~14.5 GB)
- `text_encoders/qwen3vl_8b_fp8_scaled.safetensors` (~10.6 GB)
- `vae/qwen_image_2.1_vae_bf16.safetensors` (~0.7 GB)

### 3. Upload the dataset

From your local `ComfyUI` checkout:

```bash
./push-dataset.sh
```

This packs and extracts `identity_lora_dataset2_face512` (83 img+txt pairs,
512×512) into `/workspace/ComfyUI/input/`.

### 4. Start ComfyUI and train

```bash
./runpod-pod.sh ssh <podId>
cd /workspace
./start-comfyui.sh            # UI on port 8188
./train-identity.sh           # submits workflows/qwen_image_2.1_identity_train.json
```

The training graph runs 200 steps, rank 16, lr 1e-4, batch 1 with gradient
accumulation 2, no gradient checkpointing, on the bf16 model. The LoRA is saved
to `/workspace/ComfyUI/output/loras/identity/`. To use it for generation, copy
it into the loader path and run `qwen_image_2.1_identity_t2i.json`:

```bash
cp /workspace/ComfyUI/output/loras/identity/ohwx_*.safetensors \
   /workspace/ComfyUI/models/loras/identity/
```

## Storage and cost notes

- `runpod-pod.sh` defaults to a 100 GB network volume mounted at `/workspace`
  and a 150 GB container disk. The weights, ComfyUI, and outputs all live on the
  volume, so stopping and restarting a pod keeps them.
- A 4090 is the cheapest card that fits; a 48 GB card removes all memory
  pressure during training and lets you generate at 2K in bf16.
- Set `POD_NAME`, `VOLUME_GB`, `DISK_GB`, `CLOUD_TYPE=SECURE|COMMUNITY`
  as needed. Community is cheaper but availability varies.

## Why the patch

`MakeTrainingDataset` encodes images with the VAE and captions with the text
encoder. Both outputs used to keep autograd history, so the training loop's
first backward freed the encode graph and the second step crashed. The patch
detaches those tensors at the dataset boundary; encoding is data preparation,
not part of the trained graph.
