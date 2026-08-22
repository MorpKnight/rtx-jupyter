# Jupyter GPU Workspace

[![Build and publish image](https://github.com/MorpKnight/rtx-jupyter/actions/workflows/publish-image.yml/badge.svg)](https://github.com/MorpKnight/rtx-jupyter/actions/workflows/publish-image.yml)
![Linux x86_64](https://img.shields.io/badge/platform-Linux%20x86__64-333?style=flat-square)
![NVIDIA GPU](https://img.shields.io/badge/GPU-NVIDIA-76B900?style=flat-square&logo=nvidia&logoColor=white)
![PyTorch](https://img.shields.io/badge/PyTorch-2.8.0%20%7C%20CUDA%2012.8-ee4c2c?style=flat-square&logo=pytorch&logoColor=white)

A reusable JupyterLab Docker environment for NVIDIA GPU hosts. The image packages CUDA-enabled PyTorch, common Transformer tooling, nvtop, and an isolated Codex CLI installation. Docker Compose keeps notebooks, models, datasets, Hugging Face caches, and Codex authentication on the host.

The project is designed for Arch Linux hosts with NVIDIA GPUs, including the RTX 4090 and RTX 3090 Ti, and targets other compatible Linux x86_64 systems using the NVIDIA Container Toolkit.

[Overview](#overview) · [Production deployment](#production-deployment) · [Configuration](#configuration) · [Verification](#verification) · [Cloudflare Tunnel](#cloudflare-tunnel) · [Codex CLI](#codex-cli) · [Persistence](#persistence) · [Image publishing](#image-publishing) · [Troubleshooting](#troubleshooting)

## Overview

The custom image contains:

- JupyterLab from a pinned Jupyter Docker Stacks PyTorch base image.
- PyTorch 2.8.0 with CUDA 12.8 wheels.
- transformers, accelerate, safetensors, sentencepiece, and huggingface_hub.
- nvtop and NVIDIA GPU access through Docker Compose.
- Codex CLI installed in the image as the unprivileged jovyan user.
- Codex defaults for normal execution and a separate planning profile.

The Compose deployment provides:

- One NVIDIA GPU through Compose device reservation.
- Jupyter published only on the host's Tailscale IPv4 address.
- An optional remotely-managed Cloudflare Tunnel with Cloudflare Access.
- A separate persistent Codex account for the container.
- Bind-mounted storage for notebooks, models, datasets, caches, and authentication state.

Software belongs in the image. User state belongs in host directories. Recreating a container therefore does not reinstall image dependencies or delete bind-mounted data.

## Architecture

~~~text
Tailscale client
      |
      |  http://TAILSCALE_IP:8888
      v
Jupyter container
      |
      |  /home/jovyan/work
      |  /mnt/data
      |  /home/jovyan/.codex

Internet client
      |
      |  HTTPS
      v
Cloudflare Access -> Cloudflare Edge -> cloudflared container
                                                   |
                                                   |  http://jupyter:8888
                                                   v
                                           Jupyter container
~~~

The Cloudflare connector and Jupyter service share the default Compose network. The Cloudflare origin must use the service name `jupyter`, not `localhost` and not the host Tailscale address.

## Repository layout

~~~text
.
├── .github/workflows/publish-image.yml
├── .dockerignore
├── .env.example
├── .gitignore
├── Dockerfile
├── README.md
└── compose.yaml
~~~

The repository does not contain host data, model files, Codex credentials, Jupyter tokens, or Cloudflare tunnel tokens.

## Requirements

Each deployment host needs:

- Linux x86_64.
- Docker Engine with Docker Compose v2.
- A supported NVIDIA driver and NVIDIA Container Toolkit.
- An NVIDIA GPU.
- Tailscale if private tailnet access is required.
- Network access to Quay, PyTorch's wheel index, and GHCR or the relevant registries.
- A Cloudflare-managed domain and Cloudflare One permissions if the Tunnel is enabled.

Validate the NVIDIA runtime before starting the project:

~~~bash
sudo docker run --rm --gpus all \
  nvidia/cuda:12.9.0-base-ubuntu22.04 \
  nvidia-smi
~~~

> [!NOTE]
> The container uses the host NVIDIA driver at runtime. CUDA libraries inside the image do not replace the host driver or NVIDIA Container Toolkit.

## Production deployment

The supported production Compose file is `compose.yaml`. The default production paths are:

| Purpose | W4090 | W3090 |
| --- | --- | --- |
| Compose project | `/home/giovan/docker-jupyter` | `/home/giovan/docker-jupyter` |
| Project and notebooks | `/home/giovan/docker-jupyter` | `/home/giovan/docker-jupyter` |
| Models, datasets, and cache | `/mnt/data/giovan/docker-jupyter` | `/home/giovan/docker-jupyter/data` |
| Codex state | `/mnt/data/giovan/docker-jupyter/codex` | `/home/giovan/docker-jupyter/data/codex` |

### 1. Install the repository

For a new host:

~~~bash
sudo mkdir -p /home/giovan/docker-jupyter
sudo chown "$USER:$USER" /home/giovan/docker-jupyter
git clone https://github.com/MorpKnight/rtx-jupyter.git /home/giovan/docker-jupyter
cd /home/giovan/docker-jupyter
~~~

For an existing checkout:

~~~bash
cd /home/giovan/docker-jupyter
git pull --ff-only
~~~

Do not run production and testing stacks with the same fixed container_name values on one Docker host. The production Compose file uses `docker-jupyter` and `cloudflared-jupyter`.

### 2. Create the environment file

~~~bash
cp .env.example .env
chmod 600 .env
tailscale ip -4
openssl rand -hex 32
~~~

Edit `.env` and replace every placeholder. For a prebuilt GHCR deployment, set:

~~~env
IMAGE_NAME=ghcr.io/morpknight/rtx-jupyter:latest
~~~

Do not put Codex credentials or the Cloudflare token value in `.env`.

### 3. Create persistent directories

W4090:

~~~bash
mkdir -p \
  /mnt/data/giovan/docker-jupyter/{models,datasets,checkpoints,codex,.cache/huggingface}
chmod 700 /mnt/data/giovan/docker-jupyter/codex
~~~

W3090:

~~~bash
mkdir -p \
  /home/giovan/docker-jupyter/data/{models,datasets,checkpoints,codex,.cache/huggingface}
chmod 700 /home/giovan/docker-jupyter/data/codex
~~~

### 4. Create the Cloudflare token file

Compose validates the top-level secret file during configuration. Create it before running `docker compose config`, even if the Cloudflare service will be started later:

~~~bash
mkdir -p secrets
chmod 700 secrets
install -m 600 /dev/null secrets/cloudflare-tunnel-token
$EDITOR secrets/cloudflare-tunnel-token
test -s secrets/cloudflare-tunnel-token
~~~

The path in `.env` should remain:

~~~env
CLOUDFLARE_TUNNEL_TOKEN_FILE=./secrets/cloudflare-tunnel-token
~~~

### 5. Choose the image source

For the prebuilt image published by GitHub Actions:

~~~bash
sudo docker compose config --quiet
sudo docker compose pull jupyter cloudflared
sudo docker compose up -d --no-build jupyter cloudflared
~~~

If the GHCR package is private, authenticate to GHCR before pulling:

~~~bash
sudo docker login ghcr.io
~~~

To build locally instead:

~~~bash
sudo docker compose config --quiet
sudo docker compose build jupyter
sudo docker compose up -d jupyter cloudflared
~~~

### 6. Check the deployment

~~~bash
sudo docker compose ps
sudo docker compose logs --tail=100 cloudflared
~~~

Use the verification commands below before treating the deployment as complete.

## Configuration

All supported variables are documented in `.env.example`.

| Variable | Purpose | W4090 example | W3090 example |
| --- | --- | --- | --- |
| `IMAGE_NAME` | Jupyter image | `ghcr.io/morpknight/rtx-jupyter:latest` | Same |
| `CLOUDFLARED_IMAGE` | Cloudflare connector image | `cloudflare/cloudflared:latest` | Same |
| `TAILSCALE_IP` | Host IPv4 used for the Jupyter binding | Host-specific | Host-specific |
| `PROJECT_ROOT` | Host project directory | `/home/giovan/docker-jupyter` | `/home/giovan/docker-jupyter` |
| `DATA_ROOT` | Host data, model, and cache directory | `/mnt/data/giovan/docker-jupyter` | `/home/giovan/docker-jupyter/data` |
| `CODEX_ROOT` | Host Codex state directory | `/mnt/data/giovan/docker-jupyter/codex` | `/home/giovan/docker-jupyter/data/codex` |
| `JUPYTER_TOKEN` | Jupyter authentication token | Host-specific secret | Host-specific secret |
| `CLOUDFLARE_TUNNEL_TOKEN_FILE` | Path to the local tunnel token file | `./secrets/cloudflare-tunnel-token` | Host-specific |

The Jupyter port is published only on `TAILSCALE_IP`. It is not bound to all host interfaces.

## Verification

### Compose and container state

~~~bash
sudo docker compose config --quiet
sudo docker compose config --services
sudo docker compose ps
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
~~~

Expected services:

~~~text
jupyter
cloudflared
~~~

The Cloudflare container should not have a published host port.

### GPU and PyTorch

~~~bash
sudo docker compose exec -T --user jovyan jupyter nvidia-smi
~~~

~~~bash
sudo docker compose exec -T --user jovyan jupyter \
  python -c 'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available(), torch.cuda.get_device_name(0))'
~~~

Expected output includes:

~~~text
2.8.0+cu128 12.8 True <GPU name>
~~~

### Codex

~~~bash
sudo docker compose exec -T --user jovyan jupyter \
  sh -lc 'pwd; echo "$CODEX_HOME"; command -v codex; codex --version'
~~~

Check authentication without printing the auth file:

~~~bash
sudo docker compose exec -T --user jovyan jupyter \
  codex login status
~~~

### Cloudflare connector

The `cloudflare/cloudflared` image is minimal and does not provide a shell. Verify its secret mount with Docker inspection and verify the binary directly:

~~~bash
sudo docker inspect cloudflared-jupyter \
  --format '{{range .Mounts}}{{println .Destination "RW=" .RW}}{{end}}'
~~~

~~~bash
sudo docker compose exec -T cloudflared cloudflared --version
sudo docker compose logs --tail=200 cloudflared
sudo docker compose exec -T cloudflared cloudflared tunnel diag
~~~

Connectivity pre-checks should pass DNS, Cloudflare API, and TCP or UDP connectivity to Cloudflare.

### HTTP access

Use a GET request for endpoint testing. `curl -I` sends `HEAD`, which can produce `405 Method Not Allowed` from Jupyter even when the service is healthy:

~~~bash
curl -sS -D- -o /dev/null https://<cloudflare-hostname>/
~~~

Then open the hostname in a browser and verify Cloudflare Access, the Jupyter token, JupyterLab, terminal, uploads, and WebSockets.

The Tailscale fallback URL is:

~~~text
http://<TAILSCALE_IP>:8888/?token=<JUPYTER_TOKEN>
~~~

## Cloudflare Tunnel

The Compose service is a remotely-managed `cloudflared` connector:

- Image: `cloudflare/cloudflared:latest`, overrideable with `CLOUDFLARED_IMAGE`.
- Origin: `http://jupyter:8888`.
- Secret: `/run/secrets/cloudflare_tunnel_token`.
- Host ports: none.
- GPU access: none.
- Docker socket, privileged mode, and host networking: none.

### Provisioning

Create a separate production tunnel for each host. Do not reuse the W4090 testing token for production or W3090.

In the Cloudflare Dashboard:

1. Create a remotely-managed Cloudflared tunnel for the target host.
2. Copy its Docker token into the host secret file; do not put it in Git, `.env`, the Dockerfile, or a command-line argument.
3. Add a published application route:
   - Hostname: `jupyter-w4090.<your-domain>`
   - Service: `http://jupyter:8888`
4. Create a Cloudflare Access self-hosted application for the exact hostname.
5. Add an Allow policy only for the intended users or email addresses.
6. Keep Jupyter token authentication enabled as a second layer.

Cloudflare's current guidance is available in the [self-hosted public application documentation](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/) and [Tunnel run parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/).

### Start and monitor

Before starting a new connector, check for existing Docker or systemd connectors. Do not stop an existing connector until its tunnel and hostname ownership are known:

~~~bash
sudo docker ps --format '{{.Names}}\t{{.Image}}' | grep -i cloudflared || true
systemctl is-active cloudflared.service 2>/dev/null || true
~~~

Start the production connector:

~~~bash
sudo docker compose pull cloudflared
sudo docker compose up -d cloudflared
sudo docker compose logs --tail=100 cloudflared
sudo docker compose exec -T cloudflared cloudflared tunnel diag
~~~

Cloudflare Tunnel requires outbound connectivity. If it is unhealthy, check DNS and outbound TCP or UDP port `7844`. Review the [Tunnel connectivity pre-checks](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/connectivity-prechecks/).

### WARP coexistence

This repository does not modify WARP. If WARP is active and the Tunnel fails:

1. Run `cloudflared tunnel diag`.
2. Check DNS resolution and port `7844`.
3. Inspect the actual route and resolver behavior.
4. Only then evaluate DNS-only mode or a narrowly scoped Split Tunnel profile.

Do not add broad exclusions blindly. See the [Cloudflare Split Tunnels documentation](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/).

### Rollback

Disable only the Cloudflare path while preserving Tailscale access:

~~~bash
sudo docker compose stop cloudflared
~~~

If the token is exposed, rotate it in Cloudflare, replace the secret file, and recreate only the connector:

~~~bash
sudo docker compose up -d --force-recreate cloudflared
~~~

## Codex CLI

Codex CLI is installed in the image as `jovyan`. Its account is intentionally independent from the host account.

The account state is persisted through `CODEX_ROOT` at:

~~~text
/home/jovyan/.codex
~~~

Authenticate manually with device code:

~~~bash
sudo docker compose exec -it --user jovyan \
  -w /home/jovyan/work jupyter \
  codex login --device-auth
~~~

The image includes these defaults:

| Use case | Command/profile | Model | Reasoning |
| --- | --- | --- | --- |
| Normal chat and execution | Default `codex` | `gpt-5.6-luna` | `max` |
| Planning | `codex --profile planner` | `gpt-5.6-sol` | `high` |

The defaults are copied into `CODEX_HOME` only when the host has not created them. Existing user configuration is preserved.

> [!WARNING]
> Codex authentication state is credential material. Treat `CODEX_ROOT` and its `auth.json` as sensitive. Never commit or share them.

## Models and datasets

Models and datasets are not baked into the image. Store them below `DATA_ROOT`; they appear inside the container under `/mnt/data`.

For W4090:

~~~text
Host:      /mnt/data/giovan/docker-jupyter/models/Qwen/Qwen3.5-4B
Container: /mnt/data/models/Qwen/Qwen3.5-4B
~~~

Use `local_files_only=True` when loading a model that is already present on the host to avoid an unexpected download.

## Persistence and lifecycle

| Layer | Examples | Survives container recreation? |
| --- | --- | --- |
| Image | Jupyter, PyTorch, Transformers, `nvtop`, Codex CLI | Yes, while the same image is used |
| Bind mounts | Notebooks, models, datasets, HF cache, Codex auth | Yes |
| Container writable layer | Interactive `apt` or `pip` installs | No |

Routine lifecycle commands:

~~~bash
sudo docker compose restart
sudo docker compose up -d --force-recreate jupyter cloudflared
~~~

Rebuild or pull a new image only when the Dockerfile or image tag changes:

~~~bash
sudo docker compose pull jupyter
sudo docker compose up -d --no-build jupyter cloudflared
~~~

Do not use `docker compose down -v` for routine recreation. It is unnecessary for these bind-mounted directories.

## Image publishing

The GitHub Actions workflow at `.github/workflows/publish-image.yml` publishes:

~~~text
ghcr.io/morpknight/rtx-jupyter
~~~

The workflow:

- Runs on pushes to `main`, version tags matching `v*`, and manual dispatch.
- Builds for `linux/amd64`.
- Uses GitHub Container Registry.
- Publishes `latest` for the default branch.
- Publishes short commit tags and semantic version tags for versioned releases.

Use the `IMAGE_NAME` variable to select the published image:

~~~env
IMAGE_NAME=ghcr.io/morpknight/rtx-jupyter:latest
~~~

For a more reproducible deployment, replace `latest` with the short-commit tag generated by the workflow or pin the image by digest after pulling it.

## Security boundaries

- Jupyter runs as the unprivileged `jovyan` user.
- The image does not grant `sudo`, a Linux password, `GRANT_SUDO`, or Docker socket access.
- Jupyter's direct host binding is limited to `TAILSCALE_IP`.
- Cloudflare exposure is protected by Cloudflare Access and still requires the Jupyter token.
- Cloudflare and Codex credentials remain outside the image and are excluded from Git and Docker build context.
- `cloudflared` has no GPU reservation, host port, privileged mode, or host-network access.
- `/home/jovyan/work` is the default Codex working directory, not an absolute filesystem sandbox. The process can also access `/mnt/data` by design.
- Fixed `container_name` values are host-global. Run only one stack using those names per Docker host.

## Troubleshooting

### `docker compose config --services` shows only `jupyter`

Check which Compose file is being used. The repository production file is `compose.yaml`:

~~~bash
type dc
sudo docker compose -f compose.yaml config --services
~~~

If a local shell function points to a testing-only file, it may not include the production `cloudflared` service.

### The base image cannot be pulled

The Jupyter base image is hosted on Quay. Test DNS and registry access before changing the Dockerfile:

~~~bash
getent hosts quay.io
dig @1.1.1.1 quay.io
~~~

If the image is already cached, Docker may reuse it during a local build.

### CUDA is unavailable

First confirm the host runtime, then confirm the running container image:

~~~bash
sudo docker run --rm --gpus all \
  nvidia/cuda:12.9.0-base-ubuntu22.04 \
  nvidia-smi

sudo docker compose config | sed -n '/jupyter:/,/cloudflared:/p'
sudo docker compose exec -T --user jovyan jupyter \
  python -c 'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())'
~~~

Recreate only after confirming that the correct CUDA-enabled image is selected.

### Codex is missing

Confirm that the running container uses the intended image and recreate it:

~~~bash
sudo docker compose pull jupyter
sudo docker compose up -d --force-recreate --no-build jupyter
sudo docker compose exec -T --user jovyan jupyter codex --version
~~~

### Codex or Jupyter cannot write to a bind mount

The standard image uses UID `1000` and GID `100`. Check the configured host directory and fix only the intended target:

~~~bash
sudo chown -R 1000:100 /path/to/the/configured/codex-directory
~~~

Do not apply broad ownership changes to `/mnt/data` or the whole host filesystem.

### Cloudflare returns `502`

Check all three layers:

1. The Dashboard hostname is attached to the intended tunnel.
2. The origin is exactly `http://jupyter:8888`.
3. Both containers share the same Docker network.

Jupyter origin test:

~~~bash
sudo docker compose exec -T jupyter \
  curl -sS -D- -o /dev/null http://127.0.0.1:8888
~~~

Network test from the cloudflared network:

~~~bash
sudo docker run --rm \
  --network container:cloudflared-jupyter \
  busybox:1.36 \
  wget -S -O /dev/null -T 5 http://jupyter:8888
~~~

Use a GET request for the public hostname. `curl -I` uses `HEAD` and may return `405` from Jupyter even when the Tunnel is working:

~~~bash
curl -sS -D- -o /dev/null https://<cloudflare-hostname>/
~~~

### The Cloudflare image has no shell

This is expected for the minimal connector image. Do not diagnose it with `sh -lc`. Use:

~~~bash
sudo docker compose exec -T cloudflared cloudflared --version
sudo docker compose logs --tail=200 cloudflared
sudo docker inspect cloudflared-jupyter
~~~

### WARP or DNS interferes with the Tunnel

A DNS flush on a Mac does not change DNS on a remote Linux host reached through SSH. Identify where the failing command runs, then check that host's resolver, route, and outbound port `7844`.

## References

- [Jupyter Docker Stacks](https://github.com/jupyter/docker-stacks)
- [Docker Compose GPU support](https://docs.docker.com/compose/how-tos/gpu-support/)
- [Docker Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/)
- [PyTorch previous versions](https://pytorch.org/get-started/previous-versions/)
- [Codex CLI](https://developers.openai.com/codex/cli/)
- [OpenAI authentication](https://learn.chatgpt.com/docs/auth)
- [Cloudflare Tunnel in Docker](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/update-cloudflared/)
- [Cloudflare Tunnel run parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/)
- [Cloudflare Access self-hosted public applications](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
- [Cloudflare Tunnel connectivity pre-checks](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/connectivity-prechecks/)
- [Cloudflare One Split Tunnels](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/)
- [Tailscale documentation](https://tailscale.com/kb)
