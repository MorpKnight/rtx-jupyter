<div align="center">

<h1>RTX Jupyter</h1>

<p><strong>A portable, GPU-enabled JupyterLab environment for Linux hosts with NVIDIA GPUs.</strong></p>

<p>
  <a href="https://github.com/MorpKnight/rtx-jupyter/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/MorpKnight/rtx-jupyter/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/MorpKnight/rtx-jupyter/actions/workflows/publish-image.yml"><img alt="Build and publish" src="https://github.com/MorpKnight/rtx-jupyter/actions/workflows/publish-image.yml/badge.svg"></a>
  <a href="https://github.com/MorpKnight/rtx-jupyter/pkgs/container/rtx-jupyter"><img alt="Container image" src="https://img.shields.io/badge/GHCR-rtx--jupyter-2496ED?style=flat-square&amp;logo=docker&amp;logoColor=white"></a>
  <img alt="Linux AMD64" src="https://img.shields.io/badge/platform-Linux%20AMD64-333?style=flat-square">
  <img alt="NVIDIA GPU" src="https://img.shields.io/badge/GPU-NVIDIA-76B900?style=flat-square&amp;logo=nvidia&amp;logoColor=white">
</p>

<p>
  <a href="#quick-start">Quick start</a> ·
  <a href="#access-modes">Access modes</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#operations">Operations</a> ·
  <a href="#troubleshooting">Troubleshooting</a>
</p>

</div>

RTX Jupyter packages JupyterLab, CUDA-enabled PyTorch, Hugging Face tooling, `nvtop`, and Codex CLI into one image. Notebooks, datasets, model caches, and credentials remain in separate host directories, so container recreation does not erase them or reinstall dependencies.

The same Compose project can run through localhost, Tailscale, Cloudflare Tunnel, or Tailscale and Cloudflare together. It does not assume a specific hostname, Linux distribution, username, GPU model, or host directory layout.

> [!IMPORTANT]
> This is an evergreen, latest-at-build image. A rebuild may resolve newer package versions than an earlier build from the same commit. CI records installed versions and image metadata, while production rollback should use a known image digest.

## What is included

- JupyterLab based on the latest Jupyter Docker Stacks PyTorch image available at build time.
- PyTorch, torchvision, and torchaudio from the CUDA 12.8 wheel channel.
- `transformers`, `accelerate`, `safetensors`, `sentencepiece`, and `huggingface_hub`.
- Codex CLI installed in the image, with persistent and host-isolated account state.
- `nvtop` for interactive GPU monitoring.
- NVIDIA GPU reservation through Docker Compose.
- Persistent workspace, data, Hugging Face cache, and Codex state.
- Non-root notebook runtime, health checks, bounded logs, shared-memory configuration, and graceful shutdown.
- Optional localhost, Tailscale, Cloudflare Tunnel, and resource-limit overlays.
- CI linting, secret scanning, smoke tests, vulnerability reporting, SBOM, provenance, and digest-based image promotion.

Models and datasets are intentionally not baked into the image. Store them under the configured data root or download them through Hugging Face after deployment.

## Architecture

The core stack contains Jupyter and one NVIDIA GPU reservation. Access is added with small Compose overlays:

```text
Local browser ───────────────> 127.0.0.1:8888 ─┐
Tailscale client ────────────> TAILSCALE_IP:8888 ─┼─> JupyterLab
Cloudflare Access ─> Tunnel ─> cloudflared ─────┘
                                                  │
                         NVIDIA GPU <─────────────┤
                         Workspace <──────────────┤
                         Data and HF cache <──────┤
                         Codex state <────────────┘
```

Persistent host paths are mounted as follows:

| Host setting | Container path | Purpose |
| --- | --- | --- |
| `WORKSPACE_ROOT` | `/home/jovyan/work` | Notebooks and source code |
| `DATA_ROOT` | `/mnt/data` | Models, datasets, checkpoints, and Hugging Face cache |
| `CODEX_ROOT` | `/home/jovyan/.codex` | Codex configuration and authentication |

The repository checkout, `.env`, Cloudflare token, and backup encryption key must remain outside these mounted roots.

## Requirements

- Linux AMD64 host.
- NVIDIA GPU supported by the installed host driver and the PyTorch CUDA 12.8 runtime.
- Docker Engine and Docker Compose v2.
- NVIDIA Container Toolkit configured for Docker.
- Git and OpenSSL for setup.
- Internet or registry access for either pulling the prebuilt image or building from upstream images and package indexes.

Optional requirements depend on the selected mode:

- Tailscale for tailnet-only access.
- A remotely managed Cloudflare Tunnel and Cloudflare Access policy for public hostname access.
- `age` only when backing up the complete Codex state, including authentication.

The NVIDIA kernel driver is supplied by the host. It is not installed inside the image.

### GPU preflight

First confirm that the host can expose its GPU to Docker:

```bash
nvidia-smi

docker run --rm --gpus all \
  nvidia/cuda:12.9.0-base-ubuntu22.04 \
  nvidia-smi
```

> [!NOTE]
> The project targets one NVIDIA GPU. It has been designed for modern RTX-class hardware, but compatibility ultimately depends on the host driver, NVIDIA Container Toolkit, GPU architecture, and the current PyTorch CUDA wheel.

## Quick start

These steps use the safe localhost mode. If your Docker installation requires elevated access, prepend `sudo` to Docker commands and project scripts that invoke Docker.

### 1. Clone the repository

```bash
git clone https://github.com/MorpKnight/rtx-jupyter.git
cd rtx-jupyter
```

### 2. Create persistent directories

```bash
mkdir -p workspace data state/codex
chmod 0700 state/codex
```

Compose uses `create_host_path: false`. A missing bind source causes an explicit failure instead of silently creating a root-owned directory.

### 3. Configure the deployment

```bash
cp .env.example .env
chmod 0600 .env

id -u
id -g
openssl rand -hex 32
```

Edit `.env` and replace at least these values:

```env
NB_UID=1000
NB_GID=1000
JUPYTER_TOKEN=replace-with-the-generated-token
```

Keep the localhost defaults for the first run:

```env
COMPOSE_PROJECT_NAME=rtx-jupyter
COMPOSE_FILE=compose.yaml:compose.local.yaml
IMAGE_NAME=ghcr.io/morpknight/rtx-jupyter:latest
```

### 4. Validate Compose

```bash
docker compose config --quiet
docker compose config --services
```

The default output should list only `jupyter`.

### 5. Pull or build the image

Use the latest image that passed the publishing workflow:

```bash
docker compose pull jupyter
docker compose up -d --no-build
```

Alternatively, build everything locally from the current checkout:

```bash
docker compose build --pull --no-cache jupyter
docker compose up -d --no-build
```

For a clearly separate local tag, change this before building:

```env
IMAGE_NAME=rtx-jupyter:local
```

> [!NOTE]
> A local build avoids downloading the completed image from GHCR, but it still downloads the base image and packages from Quay, PyTorch, Python package indexes, and the Codex installer.

### 6. Verify the deployment

```bash
docker compose ps
./scripts/verify.sh
./scripts/verify-gpu.sh
```

Open JupyterLab with the token stored in `.env`:

```text
http://127.0.0.1:8888/?token=<JUPYTER_TOKEN>
```

## Configuration

### Compose overlays

Choose a mode by setting `COMPOSE_FILE` in `.env`. No Compose YAML edits are required.

| Mode | `COMPOSE_FILE` | Additional settings |
| --- | --- | --- |
| Localhost | `compose.yaml:compose.local.yaml` | Optional `JUPYTER_PORT` |
| Tailscale | `compose.yaml:compose.tailscale.yaml` | `TAILSCALE_IP` |
| Cloudflare | `compose.yaml:compose.cloudflare.yaml` | `CLOUDFLARE_TUNNEL_TOKEN_FILE` |
| Tailscale + Cloudflare | `compose.yaml:compose.tailscale.yaml:compose.cloudflare.yaml` | Both settings above |

Append `compose.resources.yaml` to any mode to enable the configured CPU and memory limits.

### Storage paths

The defaults keep all persistent directories beside the checkout:

```env
WORKSPACE_ROOT=./workspace
DATA_ROOT=./data
CODEX_ROOT=./state/codex
```

For larger or production deployments, absolute paths are supported:

```env
WORKSPACE_ROOT=/srv/rtx-jupyter/workspace
DATA_ROOT=/mnt/data/rtx-jupyter
CODEX_ROOT=/var/lib/rtx-jupyter/codex
```

Create every path before starting Compose and ensure `NB_UID:NB_GID` can write to it. Keep testing and production roots separate.

### Runtime identity

Set the numeric owner of bind-mounted files:

```env
NB_UID=1000
NB_GID=1000
```

The container starts as root only long enough for the official Jupyter Docker Stacks startup process to map the notebook user and prepare mount roots. JupyterLab then runs as the mapped `jovyan` user without sudo.

### Operational defaults

```env
SHM_SIZE=2gb
PIDS_LIMIT=4096
STOP_GRACE_PERIOD=60s
LOG_MAX_SIZE=10m
LOG_MAX_FILE=3
```

When `compose.resources.yaml` is selected:

```env
CPU_LIMIT=8
MEMORY_LIMIT=32g
```

## Access modes

### Localhost

Localhost is the default and does not expose Jupyter on a LAN interface:

```env
COMPOSE_FILE=compose.yaml:compose.local.yaml
JUPYTER_PORT=8888
```

For remote use, connect through an SSH port forward or choose Tailscale or Cloudflare.

### Tailscale

Find the host's tailnet IPv4 address:

```bash
tailscale ip -4
```

Then configure:

```env
COMPOSE_FILE=compose.yaml:compose.tailscale.yaml
TAILSCALE_IP=100.x.y.z
```

Access Jupyter at:

```text
http://100.x.y.z:8888/?token=<JUPYTER_TOKEN>
```

The port is bound only to the configured Tailscale address.

### Cloudflare Tunnel

Create a dedicated, remotely managed tunnel and add a published application route in Cloudflare:

```text
jupyter.example.com -> http://jupyter:8888
```

`jupyter` is the Compose service name. Do not use `localhost:8888` as the tunnel origin.

Protect the hostname with a Cloudflare Access self-hosted application, then store the connector token outside the repository and all mounted Jupyter roots:

```bash
token_path="$HOME/.config/rtx-jupyter/cloudflare-tunnel-token"

install -d -m 0700 "$(dirname "$token_path")"
install -m 0640 /dev/null "$token_path"
$EDITOR "$token_path"
test -s "$token_path"
```

Set the absolute path in `.env`:

```env
COMPOSE_FILE=compose.yaml:compose.cloudflare.yaml
CLOUDFLARE_TUNNEL_TOKEN_FILE=/home/example/.config/rtx-jupyter/cloudflare-tunnel-token
```

The token file must be readable by the configured `NB_GID`. Compose mounts it read-only only into `cloudflared`; it is not available inside Jupyter.

Start and verify both services:

```bash
docker compose config --services
docker compose pull cloudflared
docker compose up -d
docker compose ps
docker compose logs --tail=100 cloudflared
docker compose exec -T cloudflared \
  cloudflared tunnel --metrics 127.0.0.1:2000 ready
```

Cloudflare acceptance should verify all of the following:

- An authorized Access identity can reach Jupyter.
- An unauthorized identity is denied.
- An unauthenticated browser is redirected to Access.
- Jupyter still requires its own token.
- Notebook terminals, uploads, and WebSockets work.
- Tailscale remains available when both overlays are selected.

### Tailscale and Cloudflare together

```env
COMPOSE_FILE=compose.yaml:compose.tailscale.yaml:compose.cloudflare.yaml
TAILSCALE_IP=100.x.y.z
CLOUDFLARE_TUNNEL_TOKEN_FILE=/absolute/path/to/cloudflare-tunnel-token
```

This provides a private fallback path through Tailscale while Cloudflare serves the public hostname.

## Multiple deployments

Compose project names isolate containers, networks, and other generated resources. Fixed `container_name` values are intentionally not used.

For two deployments on one host, give each one:

- A different `COMPOSE_PROJECT_NAME`.
- Separate workspace, data, and Codex roots.
- A different localhost port or Tailscale address binding where necessary.
- A separate Cloudflare tunnel token and hostname when Cloudflare is enabled.

Example project names:

```env
COMPOSE_PROJECT_NAME=rtx-jupyter-testing
```

```env
COMPOSE_PROJECT_NAME=rtx-jupyter-production
```

Generated names remain predictable, such as `rtx-jupyter-testing-jupyter-1`, without colliding with another project.

## Codex CLI

The Codex executable is part of the image. Authentication and configuration persist under `CODEX_ROOT`, making the container account independent from any Codex account or configuration on the host.

Log in interactively using device authentication:

```bash
docker compose exec -it --user jovyan \
  -w /home/jovyan/work jupyter \
  codex login --device-auth
```

Check the installation and login state:

```bash
docker compose exec -T --user jovyan jupyter codex --version
docker compose exec -T --user jovyan jupyter codex login status
```

The image seeds two configurations only when their files do not already exist:

```text
codex       -> default configuration: gpt-5.6-luna, max reasoning
codex-plan  -> planner profile: gpt-5.6-sol, high reasoning
```

Model availability still depends on the account and Codex service. The persistent files can be edited under `CODEX_ROOT`. Restarting, recreating, or upgrading the image does not overwrite existing configuration or authentication.

> [!NOTE]
> `/plan` changes the interaction's planning mode but does not automatically select the planner profile. Start `codex-plan`, or run `codex --profile planner`, when the Sol planner profile is required.

## Verification

### General checks

```bash
./scripts/verify.sh
```

The script validates Compose, the mapped UID/GID, expected mounts, writable persistent roots, HTTP health, Codex configuration, absence of sudo, and secret isolation. When Cloudflare is selected, it also verifies the connector and read-only secret mount.

Test recreation and confirm that Codex configuration hashes remain unchanged:

```bash
./scripts/verify.sh --recreate
```

### GPU checks

```bash
./scripts/verify-gpu.sh
```

This checks both `nvidia-smi` and PyTorch CUDA. Device files or a successful `nvidia-smi` call alone do not prove that the installed PyTorch build can use CUDA.

### Installed-version report

```bash
./scripts/version-report.sh | tee version-report.txt
```

The report includes image IDs and registry digests, OS and Python information, JupyterLab, PyTorch/CUDA, model dependencies, Codex, cloudflared, and `pip freeze` output.

## Operations

### Start, stop, and inspect

```bash
docker compose up -d
docker compose ps
docker compose logs --tail=200 jupyter
docker compose stop
```

Use `docker compose down` to remove containers and the project network. Bind-mounted workspace, data, and Codex state remain on the host.

### Update

Pull the latest tested published image and recreate the selected services:

```bash
./scripts/update.sh pull
```

Or rebuild all dependencies from their latest upstream versions:

```bash
./scripts/update.sh build
```

The update script records previous image IDs, registry digests, and a version report under `state/updates/`, then runs verification. A running container does not update merely because its image tag is `latest`.

Rollback to a recorded registry digest:

```bash
env IMAGE_NAME=ghcr.io/morpknight/rtx-jupyter@sha256:<previous-repo-digest> \
  docker compose --env-file .env \
  up -d --force-recreate --no-build jupyter
```

### Backup

By default, backup includes the workspace and the non-secret Codex configuration:

```bash
./scripts/backup.sh --destination /path/outside/all-mounted-roots
```

Include models and datasets explicitly:

```bash
./scripts/backup.sh \
  --destination /backup/rtx-jupyter \
  --include-data
```

The complete Codex state may contain authentication and is therefore accepted only as an encrypted `age` archive:

```bash
age-keygen -o "$HOME/.config/rtx-jupyter/backup-age-key.txt"

./scripts/backup.sh \
  --destination /backup/rtx-jupyter \
  --include-codex-state \
  --age-recipient age1example...
```

`.env`, Cloudflare tunnel tokens, nested `.codex` directories, and plaintext `auth.json` files are excluded from unencrypted archives. Every backup contains a manifest and SHA-256 checksums.

### Restore

Stop Jupyter and prepare empty target directories matching the current `.env`. Restore verifies checksums and refuses to overwrite non-empty targets.

```bash
docker compose stop jupyter

./scripts/restore.sh \
  --backup /backup/rtx-jupyter/rtx-jupyter-backup-<timestamp>
```

For encrypted Codex state:

```bash
./scripts/restore.sh \
  --backup /backup/rtx-jupyter/rtx-jupyter-backup-<timestamp> \
  --age-identity "$HOME/.config/rtx-jupyter/backup-age-key.txt"
```

Review host ownership before restarting the stack.

## Security model

- JupyterLab runs as the mapped notebook user, not root.
- The notebook user receives no sudo password, Docker socket, privileged mode, or host repository mount.
- Workspace, general data, and Codex credential state are separate bind mounts.
- `.env` and Cloudflare credentials are not mounted into Jupyter.
- Cloudflared runs non-root and receives only its read-only connector token.
- Local mode binds only to loopback; Tailscale mode binds only to the selected tailnet address.
- Cloudflare deployments should use both Cloudflare Access and Jupyter token authentication.
- `/home/jovyan/work` is Codex's working directory, not an absolute filesystem sandbox; `/mnt/data` remains accessible by design.
- Treat Jupyter tokens, Codex auth, tunnel tokens, and `age` private keys as passwords.

## CI and image publishing

Pull requests and pushes run:

- Hadolint, ShellCheck, and Gitleaks.
- Rendering tests for every Compose mode.
- A real Jupyter HTTP smoke test with a custom UID/GID.
- Codex first-run seeding and configuration-preservation checks.
- Trivy reporting for `HIGH` and `CRITICAL` findings.
- A blocking gate for fixable `CRITICAL` vulnerabilities.

Main-branch builds, release tags, manual runs, and the weekly schedule first publish a unique candidate:

```text
ghcr.io/morpknight/rtx-jupyter:build-<github-run-id>
```

That exact candidate is pulled, started, tested, scanned, and then promoted to `latest` without rebuilding it. BuildKit attaches an SBOM and max-level provenance. If a required gate fails, `latest` is not changed.

GitHub-hosted runners do not provide NVIDIA GPU passthrough. Run `./scripts/verify-gpu.sh` on a trusted GPU host before production deployment.

## Troubleshooting

### Compose loads the wrong files

```bash
echo "${COMPOSE_FILE:-<unset>}"
docker compose config --services
docker compose config
```

The default localhost mode lists only `jupyter`; Cloudflare mode also lists `cloudflared`. Remove shell aliases or wrapper functions that force an obsolete Compose filename.

### A bind source does not exist

Create the exact `WORKSPACE_ROOT`, `DATA_ROOT`, and `CODEX_ROOT` paths from `.env` before starting. This project deliberately disables automatic host-path creation.

### Jupyter restarts with permission errors

Confirm that `NB_UID` and `NB_GID` are numeric and match the intended host owner:

```bash
id -u
id -g
docker compose logs --tail=200 jupyter
```

Also verify that all three bind roots are writable by that identity. Avoid recursive ownership changes over large model or dataset trees unless that is explicitly intended.

### Docker sees the GPU but PyTorch does not

```bash
docker compose exec -T --user jovyan jupyter nvidia-smi
docker compose exec -T --user jovyan jupyter \
  python -c 'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())'
```

If PyTorch reports a CPU-only build, rebuild or pull the current project image and recreate the container. If `nvidia-smi` also fails, fix the host driver or NVIDIA Container Toolkit first.

### Cloudflare returns 502

Verify all three layers independently:

```bash
docker compose ps
docker compose logs --tail=200 cloudflared
docker compose exec -T --user jovyan jupyter \
  curl -sS -D- -o /dev/null http://127.0.0.1:8888
```

The remotely managed route must point to `http://jupyter:8888`. A healthy connector proves Cloudflare edge connectivity, but not a correct origin route or Access policy.

The official cloudflared image may not contain a shell. Use `cloudflared` subcommands, container logs, and the configured health check instead of `sh` inside that container.

### Pull or build times out

Pulling the published image primarily requires GHCR. Building locally additionally requires the Jupyter base image, PyTorch wheel index, Python packages, OS package repositories, and the Codex installer. Check host DNS and outbound HTTPS for the failing endpoint before changing the Dockerfile.

## Repository layout

```text
.
├── Dockerfile
├── compose.yaml                 # Core Jupyter and GPU service
├── compose.local.yaml           # Loopback port binding
├── compose.tailscale.yaml       # Tailscale IP binding
├── compose.cloudflare.yaml      # Cloudflare Tunnel service and secret
├── compose.resources.yaml       # Optional CPU and memory limits
├── docker/                      # Jupyter startup hooks and Codex launcher
├── scripts/                     # Verify, update, report, backup, and restore
└── .github/workflows/           # CI and image publishing
```

## References

- [Docker Engine installation](https://docs.docker.com/engine/install/)
- [Docker Compose installation](https://docs.docker.com/compose/install/linux/)
- [Docker Compose project names](https://docs.docker.com/compose/how-tos/project-name/)
- [Docker Compose GPU support](https://docs.docker.com/compose/how-tos/gpu-support/)
- [Jupyter Docker Stacks](https://jupyter-docker-stacks.readthedocs.io/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [PyTorch installation](https://pytorch.org/get-started/locally/)
- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Codex configuration](https://developers.openai.com/codex/config-reference)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- [Cloudflare Access self-hosted applications](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
