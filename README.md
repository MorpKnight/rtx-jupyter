# RTX Jupyter

[![CI](https://github.com/MorpKnight/rtx-jupyter/actions/workflows/ci.yml/badge.svg)](https://github.com/MorpKnight/rtx-jupyter/actions/workflows/ci.yml)
[![Build and publish](https://github.com/MorpKnight/rtx-jupyter/actions/workflows/publish-image.yml/badge.svg)](https://github.com/MorpKnight/rtx-jupyter/actions/workflows/publish-image.yml)
![Linux AMD64](https://img.shields.io/badge/platform-Linux%20AMD64-333?style=flat-square)
![NVIDIA GPU](https://img.shields.io/badge/GPU-NVIDIA-76B900?style=flat-square&logo=nvidia&logoColor=white)

An evergreen JupyterLab image for Linux AMD64 hosts with an NVIDIA GPU. It bundles CUDA-enabled PyTorch, Hugging Face tooling, `nvtop`, and Codex CLI while keeping notebooks, data, caches, and credentials on the host.

Choose one access mode without editing Compose YAML:

- Localhost only.
- Tailscale only.
- Cloudflare Tunnel only.
- Tailscale and Cloudflare together.

> [!IMPORTANT]
> This project deliberately installs the latest available dependencies at build time. Two builds from the same commit can differ. CI records installed versions, publishes an immutable build tag and digest, and promotes a build to `latest` only after tests and security gates pass.

## Architecture

The core Compose file does not publish a host port:

```text
WORKSPACE_ROOT -> /home/jovyan/work
DATA_ROOT      -> /mnt/data
CODEX_ROOT     -> /home/jovyan/.codex
```

Access is added through overlays:

```text
Local client    -> 127.0.0.1:8888 -> Jupyter
Tailscale       -> TAILSCALE_IP:8888 -> Jupyter
Cloudflare Edge -> cloudflared -> http://jupyter:8888
```

The repository, `.env`, and Cloudflare token must remain outside all three mounted roots.

## Included software

- Latest Jupyter Docker Stacks PyTorch notebook base at build time.
- Latest PyTorch, torchvision, and torchaudio available from the CUDA 12.8 wheel index.
- Latest `transformers`, `accelerate`, `safetensors`, `sentencepiece`, and `huggingface_hub`.
- Latest Codex CLI from the official installer.
- `nvtop` and JupyterLab.
- A `codex-plan` launcher for the planner profile.

The NVIDIA driver is supplied by the host through NVIDIA Container Toolkit; it is not included in the image.

## Requirements

- Linux AMD64.
- Docker Engine and Docker Compose v2.
- NVIDIA GPU and a compatible host driver.
- NVIDIA Container Toolkit configured for Docker.
- Registry access to Quay and GHCR, or cached images.
- Tailscale only when the Tailscale overlay is selected.
- A remotely-managed Cloudflare Tunnel and Access policy only when the Cloudflare overlay is selected.

Validate the host GPU runtime first:

```bash
sudo docker run --rm --gpus all \
  nvidia/cuda:12.9.0-base-ubuntu22.04 \
  nvidia-smi
```

## Quick start

### 1. Clone and prepare storage

```bash
git clone https://github.com/MorpKnight/rtx-jupyter.git
cd rtx-jupyter

mkdir -p workspace data state/codex
chmod 0700 state/codex
```

Compose uses `create_host_path: false`, so missing bind sources fail instead of being silently created as root-owned directories.

### 2. Configure the environment

```bash
cp .env.example .env
chmod 0600 .env
id -u
id -g
openssl rand -hex 32
```

Set `NB_UID`, `NB_GID`, and `JUPYTER_TOKEN` in `.env`. The safe default is localhost:

```env
COMPOSE_PROJECT_NAME=rtx-jupyter
COMPOSE_FILE=compose.yaml:compose.local.yaml
```

Project names isolate resources and generate deterministic names such as `rtx-jupyter-jupyter-1`. Do not add fixed `container_name` values.

### 3. Pull or build

Use the latest tested GHCR image:

```bash
sudo docker compose pull
sudo docker compose up -d --no-build
```

Or build the latest dependencies locally:

```bash
sudo docker compose build --pull --no-cache jupyter
sudo docker compose up -d
```

### 4. Verify

```bash
sudo docker compose ps
sudo ./scripts/verify.sh
sudo ./scripts/verify-gpu.sh
```

Local access:

```text
http://127.0.0.1:8888/?token=<JUPYTER_TOKEN>
```

## Access modes

Set exactly one of these `COMPOSE_FILE` values in `.env`.

### Localhost only

```env
COMPOSE_FILE=compose.yaml:compose.local.yaml
JUPYTER_PORT=8888
```

### Tailscale only

```env
COMPOSE_FILE=compose.yaml:compose.tailscale.yaml
TAILSCALE_IP=100.x.y.z
```

Obtain the address with:

```bash
tailscale ip -4
```

### Cloudflare only

```env
COMPOSE_FILE=compose.yaml:compose.cloudflare.yaml
CLOUDFLARE_TUNNEL_TOKEN_FILE=/absolute/path/to/cloudflare-tunnel-token
```

### Tailscale and Cloudflare

```env
COMPOSE_FILE=compose.yaml:compose.tailscale.yaml:compose.cloudflare.yaml
TAILSCALE_IP=100.x.y.z
CLOUDFLARE_TUNNEL_TOKEN_FILE=/absolute/path/to/cloudflare-tunnel-token
```

### Optional CPU and RAM limits

Append the resources overlay:

```env
COMPOSE_FILE=compose.yaml:compose.tailscale.yaml:compose.cloudflare.yaml:compose.resources.yaml
CPU_LIMIT=8
MEMORY_LIMIT=32g
```

The default stack does not impose CPU or RAM limits. It does use configurable operational defaults:

```env
SHM_SIZE=2gb
PIDS_LIMIT=4096
STOP_GRACE_PERIOD=60s
LOG_MAX_SIZE=10m
LOG_MAX_FILE=3
```

## Cloudflare Tunnel

Create a dedicated remotely-managed tunnel and published application route:

```text
https://jupyter.example.com -> http://jupyter:8888
```

Protect the hostname with a Cloudflare Access self-hosted application. Keep Jupyter token authentication enabled as a second layer.

Store the connector token outside the repository and all Jupyter mounts:

```bash
token_path="$HOME/.config/rtx-jupyter/cloudflare-tunnel-token"

install -d -m 0700 "$(dirname "$token_path")"
install -m 0640 /dev/null "$token_path"
chown "$(id -u):$(id -g)" "$token_path"
$EDITOR "$token_path"
test -s "$token_path"
```

The Cloudflare overlay grants the non-root connector supplementary access to `NB_GID`. The token is mounted read-only only in cloudflared.

Verify the connector:

```bash
sudo docker compose ps
sudo docker compose logs --tail=100 cloudflared
sudo docker compose exec -T cloudflared cloudflared version
sudo docker compose exec -T cloudflared \
  cloudflared tunnel --metrics 127.0.0.1:2000 ready
```

Acceptance checks:

- An authorized Access identity can reach Jupyter.
- An unauthorized identity is denied.
- An unauthenticated browser is redirected to Access.
- Jupyter still requires its token.
- Notebook terminals and WebSockets work.
- Tailscale remains available when its overlay is also selected.
- Tunnel health alerts and Access authentication logs are enabled in Cloudflare.

One connector already creates multiple edge connections. A replica on another host is optional and does not protect against loss of the only Jupyter origin.

## Host layouts

Recommended W4090 testing layout:

```text
Repository   /home/giovan/docker-jupyter-testing
Workspace    /home/giovan/docker-jupyter-testing/workspace
Data         /mnt/data/giovan/docker-jupyter-testing
Codex state  /home/giovan/.local/state/rtx-jupyter/testing/codex
Tunnel token /home/giovan/.config/rtx-jupyter/testing/cloudflare-tunnel-token
Project name rtx-jupyter-testing
```

Recommended W4090 production layout:

```text
Repository   /home/giovan/docker-jupyter
Workspace    /home/giovan/docker-jupyter/workspace
Data         /mnt/data/giovan/docker-jupyter
Codex state  /home/giovan/.local/state/rtx-jupyter/production/codex
Tunnel token /home/giovan/.config/rtx-jupyter/production/cloudflare-tunnel-token
Project name rtx-jupyter
```

W3090 can use `/home/giovan/docker-jupyter/data` when `/mnt/data` is unavailable. Testing and production must not share writable data, Codex state, tunnel credentials, or project names.

## Codex CLI

The image stores the executable under `/opt/codex`; authentication and configuration persist through `CODEX_ROOT`.

```bash
sudo docker compose exec -it --user jovyan \
  -w /home/jovyan/work jupyter \
  codex login --device-auth
```

Default launchers:

```bash
codex       # gpt-5.6-luna, max reasoning configuration
codex-plan  # planner profile: gpt-5.6-sol, high reasoning
```

The startup hook seeds missing config files only. Existing config and auth are never overwritten by restart, recreate, or image upgrade. `/plan` changes the reasoning mode; it does not automatically select the planner profile.

## Operations

### Verification

Run normal checks:

```bash
sudo ./scripts/verify.sh
```

Also recreate containers and compare Codex config hashes:

```bash
sudo ./scripts/verify.sh --recreate
```

GPU acceptance:

```bash
sudo ./scripts/verify-gpu.sh
```

### Installed-version report

```bash
sudo ./scripts/version-report.sh | tee version-report.txt
```

The report includes the image ID, OS, Python, JupyterLab, PyTorch/CUDA, model dependencies, Codex, cloudflared, and `pip freeze` output.

### Update to latest

Pull the latest tested published images:

```bash
sudo ./scripts/update.sh pull
```

Or rebuild every dependency from the latest upstream sources:

```bash
sudo ./scripts/update.sh build
```

The script records previous image IDs, registry digests, and a version report under `state/updates/`, recreates the selected services, and runs verification. A running container does not update merely because its image uses the `latest` tag.

Manual rollback example:

```bash
sudo env IMAGE_NAME=ghcr.io/morpknight/rtx-jupyter@sha256:<previous-repo-digest> \
  docker compose --env-file .env \
  up -d --force-recreate --no-build jupyter
```

### Backup

Default backup includes the workspace and non-secret Codex config:

```bash
./scripts/backup.sh --destination /path/outside/all-mounted-roots
```

Include model data explicitly:

```bash
./scripts/backup.sh \
  --destination /backup/rtx-jupyter \
  --include-data
```

To include the entire Codex state, install `age`, create a key outside the repository, and use its public recipient:

```bash
age-keygen -o "$HOME/.config/rtx-jupyter/backup-age-key.txt"

./scripts/backup.sh \
  --destination /backup/rtx-jupyter \
  --include-codex-state \
  --age-recipient age1example...
```

Full Codex state is streamed directly into an encrypted `.age` file. `.env`, Cloudflare tokens, nested `.codex` directories, and plaintext `auth.json` files are excluded from unencrypted archives.

The default backup assumes `config.toml` and `planner.config.toml` contain no inline credentials. Keep secrets in environment variables or use the encrypted full-state option.

Each backup is a timestamped directory with a manifest and SHA-256 checksums.

### Restore

Stop Jupyter first and create empty destination directories matching the current `.env`. Restore refuses non-empty targets and has no force option.

```bash
sudo docker compose stop jupyter

./scripts/restore.sh \
  --backup /backup/rtx-jupyter/rtx-jupyter-backup-<timestamp>
```

For encrypted Codex state:

```bash
./scripts/restore.sh \
  --backup /backup/rtx-jupyter/rtx-jupyter-backup-<timestamp> \
  --age-identity "$HOME/.config/rtx-jupyter/backup-age-key.txt"
```

Review host ownership after restore before starting the stack.

## CI and image publishing

Pull requests and non-main pushes run:

- Hadolint, ShellCheck, and Gitleaks.
- All Compose-mode render checks.
- Real Jupyter HTTP startup with custom UID/GID.
- Codex config preservation across restart.
- Trivy reporting for `HIGH` and `CRITICAL` findings.
- A blocking gate for fixable `CRITICAL` vulnerabilities.

Main, release tags, manual dispatch, and the weekly schedule build and push a unique candidate:

```text
ghcr.io/morpknight/rtx-jupyter:build-<github-run-id>
```

The exact candidate is pulled, tested, scanned, and then promoted to `latest`. BuildKit attaches max-level provenance and an SBOM. If any gate fails, `latest` is not changed.

GitHub-hosted runners do not validate NVIDIA passthrough. Run `verify-gpu.sh` on trusted W4090/W3090 hosts before production promotion.

## Migrating from the P0 Compose layout

P1 changes Compose interfaces but not storage contents:

1. Pull the new repository revision without starting containers.
2. Add `COMPOSE_PROJECT_NAME` and `COMPOSE_FILE` to `.env`.
3. Remove any shell alias that forces an obsolete `compose.testing.yaml`.
4. Keep the existing `WORKSPACE_ROOT`, `DATA_ROOT`, `CODEX_ROOT`, UID/GID, Jupyter token, and Cloudflare token paths.
5. Render the selected overlays with `docker compose config --quiet`.
6. Recreate testing and run both verification scripts.
7. Promote to production only after Cloudflare Access, persistence, and GPU checks pass.

No data migration is required. Generated container names will change because P1 uses the Compose project name instead of fixed names.

## Security boundaries

- Jupyter starts as root only for the official UID/GID initialization, then runs as the mapped notebook user.
- `jovyan` receives no sudo password, Docker socket, or privileged mode.
- The repository, `.env`, and tunnel token are not mounted into Jupyter.
- Cloudflared remains non-root and receives only its read-only token secret.
- Local mode binds only to loopback; Tailscale binds only to the selected tailnet address.
- Cloudflare deployments should use both Access and Jupyter authentication.
- `/home/jovyan/work` is Codex's working directory, not an absolute filesystem sandbox; `/mnt/data` remains accessible by design.
- Treat Codex auth, Jupyter tokens, age private keys, and tunnel tokens as passwords.

## Troubleshooting

Inspect the fully merged configuration first:

```bash
sudo docker compose config --quiet
sudo docker compose config --services
sudo docker compose ps
sudo docker compose logs --tail=200 jupyter
```

If Cloudflare is selected:

```bash
sudo docker compose logs --tail=200 cloudflared
sudo docker compose exec -T cloudflared cloudflared tunnel diag
```

Common causes:

- `TAILSCALE_IP` is required only when the Tailscale overlay is selected.
- The Cloudflare token path is required only when the Cloudflare overlay is selected.
- Bind roots must exist before Compose starts.
- Token mode should be `0640` with owner/group matching `NB_UID:NB_GID`.
- `cloudflared` has no shell; use its binary, healthcheck, and logs directly.
- A healthy tunnel proves edge connectivity, not origin routing or Access policy correctness.
- CUDA device visibility does not prove PyTorch CUDA; run `verify-gpu.sh`.

## References

- [Jupyter Docker Stacks](https://github.com/jupyter/docker-stacks)
- [Docker Compose project names](https://docs.docker.com/compose/how-tos/project-name/)
- [Docker Compose merge and overlays](https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/)
- [Docker Compose GPU support](https://docs.docker.com/compose/how-tos/gpu-support/)
- [Docker build attestations](https://docs.docker.com/build/ci/github-actions/attestations/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/)
- [PyTorch CUDA wheels](https://pytorch.org/get-started/locally/)
- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Codex configuration](https://developers.openai.com/codex/config-reference)
- [Cloudflare Tunnel availability](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/)
- [Cloudflare Access self-hosted applications](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
