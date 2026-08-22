# Jupyter GPU Workspace

> A reproducible JupyterLab environment for NVIDIA GPU workloads, local models, and containerized Codex CLI sessions.

![Linux x86_64](https://img.shields.io/badge/platform-Linux%20x86__64-333?style=flat-square)
![NVIDIA GPU](https://img.shields.io/badge/GPU-NVIDIA-76B900?style=flat-square&logo=nvidia&logoColor=white)
![PyTorch](https://img.shields.io/badge/PyTorch-2.8.0%20%7C%20CUDA%2012.8-ee4c2c?style=flat-square&logo=pytorch&logoColor=white)

This project builds a custom Jupyter Docker image for Linux hosts with an NVIDIA GPU and NVIDIA Container Toolkit. It is designed for the Arch Linux W4090 and W3090 hosts, while remaining reusable on compatible NVIDIA systems.

[Overview](#overview) · [Quick start](#quick-start) · [Configuration](#configuration) · [Verification](#verification) · [Codex CLI](#codex-cli) · [Persistence](#persistence) · [Troubleshooting](#troubleshooting)

## Overview

The container provides:

- JupyterLab from the pinned Jupyter Docker Stacks PyTorch image.
- PyTorch 2.8.0 with CUDA 12.8 wheels.
- transformers, accelerate, safetensors, sentencepiece, and huggingface_hub.
- nvtop and NVIDIA GPU access through Docker Compose.
- Codex CLI installed in the image and authenticated independently inside the container.
- Jupyter access bound to the host's Tailscale IPv4 address.
- Persistent notebooks, models, datasets, Hugging Face caches, and Codex configuration.

Software is baked into the image. User state is kept in host bind mounts, so recreating the container does not reinstall the image dependencies or remove local model files.

## Architecture and storage

~~~text
Tailscale client
      │  <TAILSCALE_IP>:8888
      ▼
Jupyter container (jovyan)
      ├── /home/jovyan/work   ← project and notebooks
      ├── /mnt/data           ← models, datasets, checkpoints, caches
      └── /home/jovyan/.codex ← container-specific Codex auth/config
~~~

| Purpose | Container path | W4090 host path | W3090 host path |
| --- | --- | --- | --- |
| Project, notebooks, and Codex working directory | /home/jovyan/work | /home/giovan/docker-jupyter | /home/giovan/docker-jupyter |
| Models, datasets, and Hugging Face cache | /mnt/data | /mnt/data/giovan/docker-jupyter | /home/giovan/docker-jupyter/data |
| Codex account and configuration | /home/jovyan/.codex | /mnt/data/giovan/docker-jupyter/codex | /home/giovan/docker-jupyter/data/codex |

/home/jovyan/work is Codex's default working directory. It is an operational scope, not a hard filesystem sandbox: the container can also access /mnt/data because model and dataset workflows require it.

## Project layout

~~~text
.
├── Dockerfile
├── compose.yaml
├── .env.example
├── .dockerignore
├── .gitignore
└── README.md
~~~

## Requirements

Each GPU host must provide:

- Linux x86_64.
- Docker Engine and Docker Compose.
- NVIDIA driver and NVIDIA Container Toolkit.
- Tailscale, with a reachable Tailscale IPv4 address.
- Network access to the base image registry, PyTorch wheel index, and official Codex installer during the first image build.

Validate the host GPU runtime before starting this project:

~~~bash
sudo docker run --rm --gpus all \
  nvidia/cuda:12.9.0-base-ubuntu22.04 \
  nvidia-smi
~~~

> [!NOTE]
> The image uses the host NVIDIA driver at runtime. The host driver and NVIDIA Container Toolkit must be functional before Compose can expose the GPU.

## Quick start

Run these steps on the GPU host. The commands are not intended to be run on the Mac host.

### 1. Place the project on the host

Copy or clone this directory to /home/giovan/docker-jupyter on the W4090 or W3090 host.

~~~bash
cd /home/giovan/docker-jupyter
~~~

### 2. Create the environment file

~~~bash
cp .env.example .env
chmod 600 .env
~~~

Get the host's Tailscale address and generate a Jupyter token locally:

~~~bash
tailscale ip -4
openssl rand -hex 32
~~~

Edit .env with the resulting values. Do not put Codex credentials in .env.

### 3. Create persistent directories

On W4090:

~~~bash
mkdir -p /home/giovan/docker-jupyter
mkdir -p /mnt/data/giovan/docker-jupyter/codex
chmod 700 /mnt/data/giovan/docker-jupyter/codex
~~~

On W3090:

~~~bash
mkdir -p /home/giovan/docker-jupyter
mkdir -p /home/giovan/docker-jupyter/data/codex
chmod 700 /home/giovan/docker-jupyter/data/codex
~~~

### 4. Build and start Jupyter

~~~bash
sudo docker compose config --quiet
sudo docker compose build jupyter
sudo docker compose up -d
sudo docker compose ps
~~~

The first build installs the image dependencies. A normal restart or container recreation reuses the built image.

## Configuration

.env.example contains the shared defaults. Set these values per host:

| Variable | W4090 | W3090 |
| --- | --- | --- |
| IMAGE_NAME | giovan/jupyter-gpu:cu128 | giovan/jupyter-gpu:cu128 |
| TAILSCALE_IP | Host-specific Tailscale IPv4 | Host-specific Tailscale IPv4 |
| PROJECT_ROOT | /home/giovan/docker-jupyter | /home/giovan/docker-jupyter |
| DATA_ROOT | /mnt/data/giovan/docker-jupyter | /home/giovan/docker-jupyter/data |
| CODEX_ROOT | /mnt/data/giovan/docker-jupyter/codex | /home/giovan/docker-jupyter/data/codex |
| JUPYTER_TOKEN | Host-specific secret | Host-specific secret |

The Compose file publishes port 8888 only on TAILSCALE_IP; it does not bind Jupyter to all host interfaces by default.

## Verification

Check the container and GPU:

~~~bash
sudo docker compose ps
sudo docker compose exec -T --user jovyan jupyter nvidia-smi
~~~

Check framework-level CUDA support, not only device visibility:

~~~bash
sudo docker compose exec -T --user jovyan jupyter \
  python -c 'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available(), torch.cuda.get_device_name(0))'
~~~

Expected output includes a CUDA-enabled PyTorch version such as 2.8.0+cu128, CUDA 12.8, and the host GPU name.

Check Codex and the working directory:

~~~bash
sudo docker compose exec -T --user jovyan jupyter \
  sh -lc 'pwd; echo "$CODEX_HOME"; command -v codex; codex --version'
~~~

Check nvtop:

~~~bash
sudo docker compose exec -T --user jovyan jupyter nvtop --help
~~~

Inspect mounts without printing environment values:

~~~bash
sudo docker inspect docker-jupyter \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
~~~

Access Jupyter from another Tailscale device:

~~~text
http://<TAILSCALE_IP>:8888/?token=<JUPYTER_TOKEN>
~~~

## Codex CLI

Codex CLI is installed in the Docker image as jovyan. Its account state is stored in the host directory configured by CODEX_ROOT, not in the image.

The container account is intentionally independent from the host account. Do not mount or copy the host's ~/.codex directory.

Authenticate with device code:

~~~bash
sudo docker compose exec -it --user jovyan \
  -w /home/jovyan/work jupyter \
  codex login --device-auth
~~~

Complete the displayed flow in a browser, then check the login state without displaying the auth file:

~~~bash
sudo docker compose exec -T --user jovyan jupyter \
  codex login status
~~~

> [!WARNING]
> The Codex auth cache contains credentials. Treat CODEX_ROOT and its auth.json as sensitive. Never commit, paste, or share them.

See the [Codex CLI documentation](https://developers.openai.com/codex/cli/) and [OpenAI authentication documentation](https://learn.chatgpt.com/docs/auth) for current login options.

## Local models and datasets

Models and datasets are not baked into the image. Store them under the host DATA_ROOT; they appear inside the container under /mnt/data.

For example, a host model directory such as:

~~~text
/mnt/data/giovan/docker-jupyter/models/Qwen/Qwen3.5-4B
~~~

is available inside the container at:

~~~text
/mnt/data/models/Qwen/Qwen3.5-4B
~~~

Use local_files_only=True when loading an already-downloaded model to avoid an unexpected network download.

## Persistence and lifecycle

| Layer | Examples | Survives container recreation? |
| --- | --- | --- |
| Image | PyTorch, Transformers, nvtop, Codex CLI | Yes, while the same image is used |
| Host bind mounts | Notebooks, models, datasets, HF cache, Codex auth | Yes |
| Container writable layer | Interactive apt install or pip install | No |

Restart or recreate the container:

~~~bash
sudo docker compose restart
sudo docker compose up -d --force-recreate
~~~

Rebuild only after changing the Dockerfile or image dependencies:

~~~bash
sudo docker compose build jupyter
sudo docker compose up -d
~~~

Do not rely on interactive package installation inside a running container for permanent dependencies.

## Prebuilt images

The image name is configurable through IMAGE_NAME, so the same Compose file can later consume a Docker Hub or GHCR image.

For example:

~~~env
IMAGE_NAME=ghcr.io/<owner>/jupyter-gpu:cu128-codex
~~~

Then pull and start without rebuilding locally:

~~~bash
sudo docker compose pull jupyter
sudo docker compose up -d --no-build
~~~

## Security boundaries

- The container runs as the unprivileged jovyan user.
- No sudo password, GRANT_SUDO, privileged mode, or Docker socket is used.
- Jupyter is published only on the host's Tailscale IPv4 address.
- .env and Codex auth files are excluded from Git and Docker build context.
- /home/jovyan/work is the default Codex working directory, not a strict filesystem sandbox.
- The target platform is Linux x86_64 with NVIDIA Container Toolkit; macOS is only suitable for editing or transferring the project files.

## Troubleshooting

### The base image cannot be pulled

The base image is hosted on Quay. Check host DNS and registry connectivity before changing the image:

~~~bash
getent hosts quay.io
dig @1.1.1.1 quay.io
~~~

If the base image is already cached locally, Compose can reuse it during the build.

### torch.cuda.is_available() is False

Confirm that the host nvidia-smi test works, then rebuild the custom image and recreate the container:

~~~bash
sudo docker compose build jupyter
sudo docker compose up -d --force-recreate
~~~

### codex is not found

The Codex binary is installed during the image build. Rebuild the image and verify that the container is using the newly built image:

~~~bash
sudo docker compose build jupyter
sudo docker compose up -d --force-recreate
sudo docker compose exec -T --user jovyan jupyter codex --version
~~~

### Permission denied in /home/jovyan/.codex

The host CODEX_ROOT must be writable by the container's jovyan UID/GID. The standard image uses 1000:100:

~~~bash
sudo chown -R 1000:100 /path/to/the/configured/codex-directory
~~~

### Jupyter is not reachable

Check the configured address and service state:

~~~bash
tailscale ip -4
sudo docker compose ps
sudo docker compose config --quiet
~~~

Use the Tailscale IPv4 address in the browser URL, not the LAN address or localhost from another device.

## References

- [Jupyter Docker Stacks](https://github.com/jupyter/docker-stacks)
- [Docker Compose GPU support](https://docs.docker.com/compose/how-tos/gpu-support/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/)
- [PyTorch previous versions](https://pytorch.org/get-started/previous-versions/)
- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Tailscale](https://tailscale.com/kb)
