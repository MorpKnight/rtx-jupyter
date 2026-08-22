# Jupyter GPU Workspace

> A reproducible JupyterLab environment for NVIDIA GPU workloads, local models, and containerized Codex CLI sessions.

![Linux x86_64](https://img.shields.io/badge/platform-Linux%20x86__64-333?style=flat-square)
![NVIDIA GPU](https://img.shields.io/badge/GPU-NVIDIA-76B900?style=flat-square&logo=nvidia&logoColor=white)
![PyTorch](https://img.shields.io/badge/PyTorch-2.8.0%20%7C%20CUDA%2012.8-ee4c2c?style=flat-square&logo=pytorch&logoColor=white)

This project builds a custom Jupyter Docker image for Linux hosts with an NVIDIA GPU and NVIDIA Container Toolkit. It is designed for the Arch Linux W4090 and W3090 hosts, while remaining reusable on compatible NVIDIA systems.

[Overview](#overview) · [Quick start](#quick-start) · [Configuration](#configuration) · [Verification](#verification) · [Cloudflare Tunnel](#cloudflare-tunnel) · [Codex CLI](#codex-cli) · [Persistence](#persistence) · [Troubleshooting](#troubleshooting)

## Overview

The container provides:

- JupyterLab from the pinned Jupyter Docker Stacks PyTorch image.
- PyTorch 2.8.0 with CUDA 12.8 wheels.
- transformers, accelerate, safetensors, sentencepiece, and huggingface_hub.
- nvtop and NVIDIA GPU access through Docker Compose.
- Codex CLI installed in the image and authenticated independently inside the container.
- Jupyter access bound to the host's Tailscale IPv4 address.
- An optional remotely-managed Cloudflare Tunnel with Cloudflare Access protection.
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

Internet client
      │  HTTPS
      ▼
Cloudflare Access → Cloudflare Edge → cloudflared container
                                             │  http://jupyter:8888
                                             ▼
                                      Jupyter container
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
- A Cloudflare-managed domain and permission to create a remotely-managed Tunnel and Access application if the Cloudflare path is enabled.

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

Copy or clone this directory to the GPU host. The normal W4090/W3090 project path is `/home/giovan/docker-jupyter`; for the first W4090 Tunnel test, use `/home/giovan/docker-jupyter-testing` and set `PROJECT_ROOT` to that path in `.env`.

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

### 4. Prepare the Cloudflare Tunnel secret

This step is required before `docker compose config` because Compose validates the configured secret file even when only the Jupyter service is selected. It is safe to create the file before the Cloudflare route is active; do not commit or share it.

~~~bash
mkdir -p secrets
chmod 700 secrets
install -m 600 /dev/null secrets/cloudflare-tunnel-token
$EDITOR secrets/cloudflare-tunnel-token
~~~

Ensure `.env` contains:

~~~env
CLOUDFLARE_TUNNEL_TOKEN_FILE=./secrets/cloudflare-tunnel-token
~~~

### 5. Build and start Jupyter

~~~bash
sudo docker compose config --quiet
sudo docker compose build jupyter
sudo docker compose up -d jupyter
sudo docker compose ps
~~~

The first build installs the image dependencies. A normal restart or container recreation reuses the built image. Start `cloudflared` after its Dashboard route and token are ready using the commands in [Preflight and start](#preflight-and-start).

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
| CLOUDFLARED_IMAGE | cloudflare/cloudflared:latest | cloudflare/cloudflared:latest |
| CLOUDFLARE_TUNNEL_TOKEN_FILE | ./secrets/cloudflare-tunnel-token | Host-specific secret-file path |

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

## Cloudflare Tunnel

The `cloudflared` service is a separate, non-GPU container. It uses the default Compose network to reach Jupyter by the service name `http://jupyter:8888`; it does not publish a host port, use host networking, mount the Docker socket, or require privileged mode. The Tailscale binding remains available as the fallback path.

The first deployment is intended for W4090 testing:

~~~text
Tunnel name:    rtx-jupyter-w4090
Public host:    jupyter-w4090.<your-cloudflare-domain>
Origin:         http://jupyter:8888
Token file:     /home/giovan/docker-jupyter-testing/secrets/cloudflare-tunnel-token
~~~

### Provision the Tunnel and Access application

In the Cloudflare Dashboard:

1. Open **Networking → Tunnels**, create a new **Cloudflared** tunnel, and choose the remotely-managed/Docker connector instructions.
2. Name it `rtx-jupyter-w4090` and copy its token. Do not paste the token into Git, `.env`, the Dockerfile, or a shell command that will remain in history.
3. Add a published application route with a hostname such as `jupyter-w4090.example.com` and the service `http://jupyter:8888`.
4. Create a **Self-hosted** Access application for that hostname.
5. Add an **Allow** policy only for the intended user or email address. Keep the default deny behavior for everyone else.
6. If the dashboard offers **Protect with Access** for the tunnel route, enable it so the origin also validates the Access token.

Cloudflare recommends creating the Access application before publishing the route; otherwise the published application can be reachable without Access protection. See the [self-hosted public application guide](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/).

### Store the token as a Docker secret

On W4090, from `/home/giovan/docker-jupyter-testing`:

~~~bash
mkdir -p secrets
chmod 700 secrets
install -m 600 /dev/null secrets/cloudflare-tunnel-token
$EDITOR secrets/cloudflare-tunnel-token
test -s secrets/cloudflare-tunnel-token
~~~

The Compose file mounts this file at `/run/secrets/cloudflare_tunnel_token` and sets `TUNNEL_TOKEN_FILE` for `cloudflared`. The token-file option is supported by `cloudflared` 2025.4.0 and newer; the default `latest` image is intended to satisfy this requirement. See the [cloudflared run parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/).

### Preflight and start

Before starting the new connector, check whether another Docker or systemd connector already exists. Do not stop an existing connector until you know which tunnel or hostname it serves.

~~~bash
cd /home/giovan/docker-jupyter-testing
sudo docker ps --format '{{.Names}}\t{{.Image}}' | grep -i cloudflared || true
systemctl is-active cloudflared.service 2>/dev/null || true
~~~

After the W4090 tunnel route and secret file are ready:

~~~bash
sudo docker compose config --quiet
sudo docker compose pull cloudflared
sudo docker compose up -d jupyter cloudflared
sudo docker compose ps
sudo docker compose logs --tail=100 cloudflared
~~~

Run the connector diagnostics without starting another long-lived tunnel:

~~~bash
sudo docker compose run --rm --no-deps cloudflared tunnel diag
~~~

Cloudflare Tunnel uses outbound-only connections. Verify that DNS works and that outbound TCP or UDP port `7844` is permitted if the connector cannot become healthy. The [Tunnel connectivity pre-checks](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/connectivity-prechecks/) document the current checks.

### Acceptance test

Confirm all of the following:

- The W4090 tunnel is **Healthy** in the Cloudflare Dashboard.
- `https://jupyter-w4090.<your-cloudflare-domain>` first applies Cloudflare Access.
- An allowed user can open JupyterLab; an unallowed user is denied.
- Jupyter still requires its token after Cloudflare Access.
- Notebook execution, terminal, uploads, and Jupyter WebSockets work through the hostname.
- `http://<TAILSCALE_IP>:8888/?token=<JUPYTER_TOKEN>` still works through Tailscale.
- `nvidia-smi`, PyTorch CUDA, and Codex checks from the [Verification](#verification) section still pass.
- `sudo docker compose restart cloudflared` reconnects the tunnel.
- `sudo docker compose up -d --force-recreate` preserves Jupyter, Codex state, models, and datasets.

### WARP coexistence

No WARP changes are made by this repository. If the tunnel fails while WARP is active, collect `tunnel diag` output first, then inspect DNS and outbound port `7844`. Evaluate DNS-only mode or a carefully scoped Split Tunnel profile only after observing the actual route behavior; do not add broad exclusions blindly. See the [Cloudflare Split Tunnels documentation](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/).

### W3090 and rollback

W3090 should use a separate remotely-managed Tunnel, hostname, and token file. Do not reuse the W4090 connector token between hosts.

To disable only the Cloudflare path while keeping Tailscale available:

~~~bash
sudo docker compose stop cloudflared
~~~

If a token was exposed, rotate it in the Cloudflare Dashboard, replace the secret file, and recreate only the connector:

~~~bash
sudo docker compose up -d --force-recreate cloudflared
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
- Cloudflare Tunnel auth is mounted as a Compose secret; `.env`, the secret directory, and Codex auth files are excluded from Git and Docker build context.
- Cloudflare Access and the Jupyter token are separate authentication layers.
- `cloudflared` has no host port, GPU reservation, or host-network access; it only makes outbound Tunnel connections and reaches the origin over the private Compose network.
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

### The Cloudflare secret file is missing

Compose validates the top-level secret before creating services. Confirm that the path in `.env` exists relative to the project directory:

~~~bash
test -s secrets/cloudflare-tunnel-token
sudo docker compose config --quiet
~~~

If the token file was moved, update `CLOUDFLARE_TUNNEL_TOKEN_FILE` in `.env`. Never replace it with the token value itself.

### The Tunnel is not healthy

Inspect the connector logs and run the diagnostic command:

~~~bash
sudo docker compose ps cloudflared
sudo docker compose logs --tail=200 cloudflared
sudo docker compose run --rm --no-deps cloudflared tunnel diag
~~~

The connector needs DNS resolution and outbound TCP or UDP access to Cloudflare on port `7844`. Check the host firewall, resolver, and WARP routing before changing the Compose file.

### Cloudflare returns 502 or cannot reach Jupyter

The published application route must use the Compose service name and container port, not the host Tailscale address:

~~~text
http://jupyter:8888
~~~

Check that Jupyter is running and listening inside its container:

~~~bash
sudo docker compose ps jupyter
sudo docker compose logs --tail=100 jupyter
sudo docker compose exec -T jupyter curl -I http://127.0.0.1:8888
~~~

### WARP interferes with the Tunnel

Do not add a broad WARP exclusion as a first response. Capture `tunnel diag`, compare DNS resolution, and verify port `7844`; then evaluate DNS-only mode or a narrowly scoped Split Tunnel profile. See the [WARP coexistence](#warp-coexistence) guidance above.

## References

- [Jupyter Docker Stacks](https://github.com/jupyter/docker-stacks)
- [Docker Compose GPU support](https://docs.docker.com/compose/how-tos/gpu-support/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/)
- [PyTorch previous versions](https://pytorch.org/get-started/previous-versions/)
- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Tailscale](https://tailscale.com/kb)
- [Cloudflare Tunnel in Docker](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/update-cloudflared/)
- [Cloudflare Tunnel run parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/)
- [Cloudflare Access self-hosted public applications](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
- [Cloudflare Tunnel connectivity pre-checks](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/connectivity-prechecks/)
- [Cloudflare One Split Tunnels](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/)
