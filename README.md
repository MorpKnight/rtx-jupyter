# RTX Jupyter

[![Build and publish image](https://github.com/MorpKnight/rtx-jupyter/actions/workflows/publish-image.yml/badge.svg)](https://github.com/MorpKnight/rtx-jupyter/actions/workflows/publish-image.yml)
![Linux x86_64](https://img.shields.io/badge/platform-Linux%20x86__64-333?style=flat-square)
![NVIDIA GPU](https://img.shields.io/badge/GPU-NVIDIA-76B900?style=flat-square&logo=nvidia&logoColor=white)
![PyTorch](https://img.shields.io/badge/PyTorch-2.8.0%20%7C%20CUDA%2012.8-ee4c2c?style=flat-square&logo=pytorch&logoColor=white)

A reusable JupyterLab environment for Linux x86_64 hosts with NVIDIA GPUs. The image bundles CUDA-enabled PyTorch, common Hugging Face tooling, `nvtop`, and Codex CLI. Docker Compose keeps notebooks, model data, Codex state, and Cloudflare credentials outside the image and in separate host directories.

The project has been exercised with RTX 4090 and RTX 3090 Ti hosts. Other NVIDIA GPUs can work when their host driver, architecture, CUDA compatibility, and NVIDIA Container Toolkit are suitable.

[Quick start](#quick-start) · [Configuration](#configuration) · [Verification](#verification) · [Codex CLI](#codex-cli) · [Cloudflare Tunnel](#cloudflare-tunnel) · [Migration](#migration-from-the-legacy-layout) · [CI](#image-publishing-and-ci)

## What is included

The image contains:

- JupyterLab from a pinned Jupyter Docker Stacks PyTorch image.
- PyTorch `2.8.0+cu128`, torchvision `0.23.0`, and torchaudio `2.8.0`.
- `transformers`, `accelerate`, `safetensors`, `sentencepiece`, and `huggingface_hub`.
- `nvtop`.
- Codex CLI installed under `/opt/codex` and exposed as `/usr/local/bin/codex`.
- A separate `codex-plan` launcher for the planner profile.

Compose provides:

- One NVIDIA GPU through a Compose device reservation.
- Jupyter bound only to the host's Tailscale IPv4 address.
- An optional remotely-managed Cloudflare Tunnel connector.
- Host UID/GID mapping through the inherited Jupyter Docker Stacks startup process.
- Separate bind mounts for work, data, and Codex account state.

Dependencies installed by the Dockerfile survive container recreation because they belong to the image. Notebooks, models, datasets, caches, and Codex authentication survive because they belong to bind-mounted host directories.

## Architecture

```text
Tailscale client
    -> TAILSCALE_IP:8888
    -> Jupyter token
    -> jupyter container

Internet client
    -> Cloudflare Access
    -> Cloudflare Edge
    -> cloudflared container
    -> http://jupyter:8888
    -> Jupyter token
```

The Jupyter container receives only these host trees:

```text
WORKSPACE_ROOT -> /home/jovyan/work
DATA_ROOT      -> /mnt/data
CODEX_ROOT     -> /home/jovyan/.codex
```

The repository checkout, `.env`, and Cloudflare token file must remain outside all three trees. The tunnel token is mounted read-only only into `cloudflared` at `/run/secrets/cloudflare_tunnel_token`.

> [!IMPORTANT]
> A remotely-managed Cloudflare Tunnel token is sufficient to run that tunnel. Treat it as a credential, keep it out of the Jupyter mounts, and rotate it if it was previously exposed. See [Cloudflare Tunnel permissions](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/).

## Requirements

- Linux x86_64.
- Docker Engine and Docker Compose v2.
- An NVIDIA GPU with a compatible host driver.
- NVIDIA Container Toolkit configured for Docker.
- Tailscale for direct private access.
- A Cloudflare-managed hostname and Cloudflare Access configuration when using the tunnel.
- Registry access to Quay and GHCR, or a cached base/prebuilt image.

Validate the host GPU runtime first:

```bash
sudo docker run --rm --gpus all \
  nvidia/cuda:12.9.0-base-ubuntu22.04 \
  nvidia-smi
```

The host driver is injected at runtime. CUDA libraries inside the image do not replace the host driver or NVIDIA Container Toolkit.

## Quick start

### 1. Clone the repository

```bash
git clone https://github.com/MorpKnight/rtx-jupyter.git
cd rtx-jupyter
```

### 2. Create the persistent directories

The portable defaults keep runtime state below the checkout while ensuring that the checkout itself is not mounted into Jupyter:

```bash
install -d -m 0755 workspace data
install -d -m 0700 state/codex secrets
```

Compose uses `create_host_path: false`. Missing directories therefore cause startup to fail instead of being silently created as root-owned paths.

### 3. Configure the environment

```bash
cp .env.example .env
chmod 600 .env
id -u
id -g
tailscale ip -4
openssl rand -hex 32
```

Edit `.env` and replace every placeholder. Set `NB_UID` and `NB_GID` to the numeric values printed by `id`.

### 4. Add the Cloudflare token

Compose validates the top-level secret even when only its configuration is being rendered:

```bash
install -m 0640 /dev/null secrets/cloudflare-tunnel-token
chown "$(id -u):$(id -g)" secrets/cloudflare-tunnel-token
$EDITOR secrets/cloudflare-tunnel-token
test -s secrets/cloudflare-tunnel-token
```

Store only the token value in the file. Do not add it to `.env`, a Docker command, the image, or Git. The file must be owned by `NB_UID:NB_GID` with mode `0640`: Compose grants the non-root `cloudflared` process supplementary access to `NB_GID`, while the secret remains read-only inside that container.

### 5. Build or pull the image

Build locally:

```bash
sudo docker compose config --quiet
sudo docker compose build jupyter
sudo docker compose up -d jupyter cloudflared
```

Or use the image published by GitHub Actions by changing `.env`:

```env
IMAGE_NAME=ghcr.io/morpknight/rtx-jupyter:latest
```

Then run:

```bash
sudo docker compose config --quiet
sudo docker compose pull jupyter cloudflared
sudo docker compose up -d --no-build jupyter cloudflared
```

For reproducible deployments, prefer a version, commit, or digest instead of `latest`.

## Host layouts

The repository defaults are portable relative directories. These are the recommended isolated layouts for Giovan's hosts.

### W4090 testing

```text
Repository     /home/giovan/docker-jupyter-testing
Workspace      /home/giovan/docker-jupyter-testing/workspace
Data           /mnt/data/giovan/docker-jupyter-testing
Codex state    /home/giovan/.local/state/rtx-jupyter/testing/codex
Tunnel token   /home/giovan/.config/rtx-jupyter/testing/cloudflare-tunnel-token
```

Create them without changing ownership of unrelated paths:

```bash
sudo install -d -o "$(id -u)" -g "$(id -g)" -m 0755 \
  /home/giovan/docker-jupyter-testing/workspace \
  /mnt/data/giovan/docker-jupyter-testing

install -d -m 0700 \
  /home/giovan/.local/state/rtx-jupyter/testing/codex \
  /home/giovan/.config/rtx-jupyter/testing

install -m 0640 /dev/null \
  /home/giovan/.config/rtx-jupyter/testing/cloudflare-tunnel-token

chown "$(id -u):$(id -g)" \
  /home/giovan/.config/rtx-jupyter/testing/cloudflare-tunnel-token
```

Use these `.env` values:

```env
WORKSPACE_ROOT=/home/giovan/docker-jupyter-testing/workspace
DATA_ROOT=/mnt/data/giovan/docker-jupyter-testing
CODEX_ROOT=/home/giovan/.local/state/rtx-jupyter/testing/codex
CLOUDFLARE_TUNNEL_TOKEN_FILE=/home/giovan/.config/rtx-jupyter/testing/cloudflare-tunnel-token
```

Testing and production intentionally do not share writable model data, cache, Codex authentication, or tunnel credentials.

### W4090 production

```text
Repository     /home/giovan/docker-jupyter
Workspace      /home/giovan/docker-jupyter/workspace
Data           /mnt/data/giovan/docker-jupyter
Codex state    /home/giovan/.local/state/rtx-jupyter/production/codex
Tunnel token   /home/giovan/.config/rtx-jupyter/production/cloudflare-tunnel-token
```

Production rollout should occur only after the W4090 testing acceptance checks pass.

### W3090 production

The same image and Compose file can be used. A host without the separate `/mnt/data` filesystem can use:

```env
WORKSPACE_ROOT=/home/giovan/docker-jupyter/workspace
DATA_ROOT=/home/giovan/docker-jupyter/data
CODEX_ROOT=/home/giovan/.local/state/rtx-jupyter/production/codex
CLOUDFLARE_TUNNEL_TOKEN_FILE=/home/giovan/.config/rtx-jupyter/production/cloudflare-tunnel-token
```

`CODEX_ROOT` must not be nested inside `DATA_ROOT`.

## Configuration

| Variable | Purpose | Portable default |
| --- | --- | --- |
| `IMAGE_NAME` | Local or published Jupyter image | `giovan/jupyter-gpu:cu128` |
| `CLOUDFLARED_IMAGE` | Cloudflare connector image | `cloudflare/cloudflared:latest` |
| `TAILSCALE_IP` | Host address used for the Jupyter port binding | Required |
| `NB_UID` | Numeric notebook-user UID | `1000` |
| `NB_GID` | Numeric notebook-user primary GID | `1000` |
| `WORKSPACE_ROOT` | Notebook and source workspace | `./workspace` |
| `DATA_ROOT` | Models, datasets, checkpoints, and HF cache | `./data` |
| `CODEX_ROOT` | Persistent Codex auth and configuration | `./state/codex` |
| `JUPYTER_TOKEN` | Jupyter authentication token | Required |
| `CLOUDFLARE_TUNNEL_TOKEN_FILE` | File containing the tunnel token | `./secrets/cloudflare-tunnel-token` |

`PROJECT_ROOT` is no longer supported. Replace it with `WORKSPACE_ROOT` before recreating the service.

The Jupyter container starts as root only so the inherited Jupyter Docker Stacks `start.sh` can map `jovyan` to `NB_UID:NB_GID` and fix the three mount roots. A startup hook then prepares only the required Jupyter/XDG runtime directories before Jupyter launches as the mapped notebook user. `GRANT_SUDO` is not enabled, and recursive ownership changes are not performed at startup.

The Cloudflare token is a file-backed Compose secret. Docker Compose preserves the host file ownership for this type of secret, so the connector receives `NB_GID` as a supplementary group and the host file uses mode `0640`. The secret is mounted read-only only in `cloudflared`.

## Verification

### Compose and process state

```bash
sudo docker compose config --quiet
sudo docker compose config --services
sudo docker compose ps
sudo docker compose top jupyter
```

Expected services:

```text
jupyter
cloudflared
```

The Jupyter server process shown by `docker compose top` must run as the mapped notebook user, not root. The `cloudflared` service must not publish a host port.

Verify the user and write access:

```bash
sudo docker compose exec -T --user jovyan jupyter \
  sh -lc '
    id
    touch /home/jovyan/work/.p0-write-test
    touch /mnt/data/.p0-write-test
    touch "$CODEX_HOME/.p0-write-test"
    rm /home/jovyan/work/.p0-write-test \
       /mnt/data/.p0-write-test \
       "$CODEX_HOME/.p0-write-test"
    if sudo -n true 2>/dev/null; then
      echo "unexpected sudo access" >&2
      exit 1
    fi
  '
```

### Mount and secret isolation

Inspect the actual host sources:

```bash
sudo docker inspect docker-jupyter \
  --format '{{range .Mounts}}{{println .Source "->" .Destination "RW=" .RW}}{{end}}'
```

Only the configured workspace, data, and Codex roots should appear in the Jupyter container. Confirm that the Cloudflare secret target is absent:

```bash
sudo docker compose exec -T --user jovyan jupyter \
  sh -lc 'test ! -e /run/secrets/cloudflare_tunnel_token'
```

Confirm that the secret is read-only in `cloudflared`:

```bash
sudo docker inspect cloudflared-jupyter \
  --format '{{range .Mounts}}{{println .Destination "RW=" .RW}}{{end}}'

sudo docker inspect cloudflared-jupyter \
  --format '{{json .HostConfig.GroupAdd}}'
```

Expected secret mount:

```text
/run/secrets/cloudflare_tunnel_token RW= false
["<NB_GID>"]
```

### GPU and PyTorch

```bash
sudo docker compose exec -T --user jovyan jupyter nvidia-smi
```

```bash
sudo docker compose exec -T --user jovyan jupyter \
  python -c 'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available(), torch.cuda.get_device_name(0))'
```

Expected output includes:

```text
2.8.0+cu128 12.8 True <GPU name>
```

### Codex installation and persistence

```bash
sudo docker compose exec -T --user jovyan jupyter \
  sh -lc '
    pwd
    echo "$CODEX_HOME"
    command -v codex
    command -v codex-plan
    codex --version
    codex-plan --version
    ls -l "$CODEX_HOME/config.toml" "$CODEX_HOME/planner.config.toml"
  '
```

Record hashes, recreate, and compare them:

```bash
sudo docker compose exec -T --user jovyan jupyter \
  sha256sum /home/jovyan/.codex/config.toml \
            /home/jovyan/.codex/planner.config.toml

sudo docker compose up -d --force-recreate jupyter cloudflared

sudo docker compose exec -T --user jovyan jupyter \
  sha256sum /home/jovyan/.codex/config.toml \
            /home/jovyan/.codex/planner.config.toml
```

The before/after hashes must match. The startup hook only seeds missing files.

### Cloudflare and Tailscale

```bash
sudo docker compose exec -T cloudflared cloudflared --version
sudo docker compose logs --tail=200 cloudflared
sudo docker compose exec -T cloudflared cloudflared tunnel diag
```

Use a GET request when testing the public hostname. `curl -I` sends `HEAD`, which Jupyter may answer with `405` even when the route works:

```bash
curl -sS -D- -o /dev/null https://<cloudflare-hostname>/
```

Also verify the Tailscale fallback:

```text
http://<TAILSCALE_IP>:8888/?token=<JUPYTER_TOKEN>
```

## Codex CLI

The Codex installation and the container account are independent from Codex on the host. Authenticate manually with device code:

```bash
sudo docker compose exec -it --user jovyan \
  --workdir /home/jovyan/work jupyter \
  codex login --device-auth
```

Check login state without printing the credential file:

```bash
sudo docker compose exec -T --user jovyan jupyter codex login status
```

The first startup seeds these defaults only when the corresponding file is absent:

| Use | Command | Model | Reasoning |
| --- | --- | --- | --- |
| Normal chat and execution | `codex` | `gpt-5.6-luna` | `max` |
| `/plan` within a normal session | `/plan` | `gpt-5.6-luna` | `high` |
| Dedicated planner profile | `codex-plan` | `gpt-5.6-sol` | `high` |

`/plan` changes plan-mode reasoning but does not automatically switch the model. Use `codex-plan` or `codex --profile planner` to start a Sol-backed planner session. Profile files live in `CODEX_HOME` and are selected explicitly with `--profile`, as documented in the [official Codex configuration reference](https://developers.openai.com/codex/config-reference).

> [!WARNING]
> `model_reasoning_effort = "max"` is intentionally experimental here. The current configuration reference documents values only through `xhigh`. If a future Codex version rejects `max`, do not silently change the deployment to `xhigh`; stop image promotion and decide the migration explicitly.

After login, use `/status` interactively in both `codex` and `codex-plan` to confirm the effective model and reasoning level. Then restart and force-recreate the service and confirm that `codex login status` remains authenticated.

## Cloudflare Tunnel

The `cloudflared` service uses a remotely-managed tunnel:

- Origin: `http://jupyter:8888`.
- Token source: `TUNNEL_TOKEN_FILE=/run/secrets/cloudflare_tunnel_token`.
- Host ports: none.
- GPU access: none.
- Docker socket, privileged mode, and host networking: none.

The token-file parameter is supported for remotely-managed tunnels by `cloudflared` 2025.4.0 and later. See [Cloudflare Tunnel run parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/).

In the Cloudflare Dashboard:

1. Create a separate tunnel for each host and environment.
2. Route the public hostname to `http://jupyter:8888`.
3. Create a self-hosted Cloudflare Access application for that hostname.
4. Add an Allow policy only for intended identities.
5. Keep Jupyter token authentication enabled as a second layer.

If a token was previously stored under a directory mounted into Jupyter, refresh it in Cloudflare, replace the external token file, and recreate only `cloudflared`.

Rollback does not require stopping Jupyter:

```bash
sudo docker compose stop cloudflared
```

Tailscale remains the recovery path.

## Migration from the legacy layout

P0 intentionally changes the storage contract:

- `PROJECT_ROOT` becomes `WORKSPACE_ROOT`.
- The repository checkout is no longer the notebook workspace.
- `CODEX_ROOT` must move outside `DATA_ROOT`.
- The tunnel token should move outside the checkout and all Jupyter mounts.

Do not recreate production until these changes have been prepared.

### Move existing Codex state safely

The old W4090 location was:

```text
/mnt/data/giovan/docker-jupyter/codex
```

The new production location is:

```text
/home/giovan/.local/state/rtx-jupyter/production/codex
```

Migration procedure:

1. Stop the Jupyter service so auth/config files cannot change during copying.
2. Create the destination with mode `0700` and the configured `NB_UID:NB_GID` owner.
3. Copy the old directory with metadata preserved.
4. Compare source and destination before changing `.env`.
5. Move the old source to a backup outside `DATA_ROOT`.
6. Start the new deployment and verify login/config persistence.
7. Keep the backup until testing, restart, and force-recreate have passed.

Example copy and comparison commands:

```bash
sudo docker compose stop jupyter

install -d -m 0700 \
  /home/giovan/.local/state/rtx-jupyter/production/codex

rsync -a \
  /mnt/data/giovan/docker-jupyter/codex/ \
  /home/giovan/.local/state/rtx-jupyter/production/codex/

diff -qr \
  /mnt/data/giovan/docker-jupyter/codex \
  /home/giovan/.local/state/rtx-jupyter/production/codex
```

Do not leave the legacy credential directory under `DATA_ROOT`: `/mnt/data` is intentionally accessible to notebooks and Codex. Relocate it to an external backup only after the comparison succeeds.

Existing `config.toml` and `planner.config.toml` files are preserved. Review and merge the desired model defaults manually; the image will not overwrite them.

### Start with an empty workspace

Create `/home/giovan/docker-jupyter/workspace` and copy only the notebooks or projects that should be available in Jupyter. Do not copy the deployment `.env`, `secrets`, or Codex state into the workspace.

## Models and datasets

Models are not baked into the image. Store them below `DATA_ROOT`; they appear at `/mnt/data` in the container.

Example W4090 production mapping:

```text
Host:      /mnt/data/giovan/docker-jupyter/models/Qwen/Qwen3.5-4B
Container: /mnt/data/models/Qwen/Qwen3.5-4B
```

Use `local_files_only=True` when loading a model already present on the host to avoid unexpected downloads.

## Persistence

| Layer | Examples | Survives recreation? |
| --- | --- | --- |
| Image | Jupyter, CUDA PyTorch, Transformers, `nvtop`, Codex CLI | Yes |
| `WORKSPACE_ROOT` | Notebooks and source code | Yes |
| `DATA_ROOT` | Models, datasets, checkpoints, HF cache | Yes |
| `CODEX_ROOT` | Codex auth and user configuration | Yes |
| Container writable layer | Interactive `apt` or `pip` changes | No |

Routine recreation does not reinstall dependencies:

```bash
sudo docker compose restart
sudo docker compose up -d --force-recreate jupyter cloudflared
```

Build or pull a new image only when the image changes.

## Image publishing and CI

`.github/workflows/publish-image.yml` builds `linux/amd64` images for:

```text
ghcr.io/morpknight/rtx-jupyter
```

Before publishing, CI now:

- Builds and loads a local smoke-test image.
- Validates Compose using isolated temporary paths.
- Runs the inherited startup process as the default notebook user.
- Verifies first-run Codex config seeding and both Codex launchers.
- Repeats startup with a non-default UID/GID and writable bind mounts.
- Publishes only if all CPU-side smoke tests pass.

GitHub-hosted runners do not validate NVIDIA passthrough. GPU, CUDA, Cloudflare, Tailscale, and interactive Codex model checks remain W4090 testing acceptance requirements.

## Security boundaries

- Jupyter runs as the mapped notebook user after root-only startup initialization.
- `jovyan` has no passwordless sudo and no Docker socket access.
- Jupyter binds only to `TAILSCALE_IP`, not every host interface.
- Cloudflare exposure should be protected by Access and Jupyter authentication.
- The Cloudflare token is available only to `cloudflared`.
- Codex authentication is intentionally available to Codex through its dedicated state mount.
- The Jupyter token is an application credential, not a security boundary from code already running inside the Jupyter container.
- `/home/jovyan/work` is Codex's working directory, not an absolute filesystem sandbox; `/mnt/data` remains accessible by design.
- Fixed `container_name` values mean production and testing need different local overrides if they run simultaneously on one Docker host.

## Troubleshooting

### Compose reports a missing bind source

This is expected when a configured directory does not exist. Create exactly the missing `WORKSPACE_ROOT`, `DATA_ROOT`, or `CODEX_ROOT` path, then rerun:

```bash
sudo docker compose config --quiet
sudo docker compose up -d
```

### Codex config is not updated after rebuilding

The startup hook never overwrites existing files. Inspect `CODEX_ROOT/config.toml` and `CODEX_ROOT/planner.config.toml`, back them up, and merge changes explicitly.

### A mount is not writable

Check the host UID/GID and mount root:

```bash
id -u
id -g
sudo docker compose exec -T --user jovyan jupyter id
sudo docker inspect docker-jupyter \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

Correct ownership only on the intended mount. Do not recursively chown `/mnt/data`, `/home`, or another broad host directory.

If the log specifically mentions `/home/jovyan/.local/share`, rebuild the image so the `05-prepare-jupyter-dirs` startup hook is present. The hook repairs only the required Jupyter/XDG runtime directories after UID/GID mapping.

### Cloudflared cannot read the tunnel token

File-backed Compose secrets preserve host ownership. Confirm that the token group matches `NB_GID`, that group-read is enabled, and that Compose passed the same group to the connector:

```bash
token_path=/path/from/CLOUDFLARE_TUNNEL_TOKEN_FILE
stat -c '%a %u:%g %n' "$token_path"
sudo docker inspect cloudflared-jupyter \
  --format '{{json .HostConfig.GroupAdd}}'
```

For `NB_UID=1002` and `NB_GID=1002`, the expected values are `640 1002:1002` and `["1002"]`. Correct only the token file:

```bash
chown "$(id -u):$(id -g)" "$token_path"
chmod 0640 "$token_path"
sudo docker compose up -d --force-recreate cloudflared
```

### CUDA is unavailable

Validate the host runtime first, then inspect PyTorch inside the actual Compose service:

```bash
sudo docker run --rm --gpus all \
  nvidia/cuda:12.9.0-base-ubuntu22.04 \
  nvidia-smi

sudo docker compose exec -T --user jovyan jupyter \
  python -c 'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())'
```

### Cloudflare returns `502`

Confirm that both services share the same Compose network and that the remotely-managed route uses exactly `http://jupyter:8888`.

Origin test:

```bash
sudo docker compose exec -T --user jovyan jupyter \
  curl -sS -D- -o /dev/null http://127.0.0.1:8888
```

The official `cloudflare/cloudflared` image has no shell. Use its binary and logs directly:

```bash
sudo docker compose exec -T cloudflared cloudflared --version
sudo docker compose logs --tail=200 cloudflared
```

## References

- [Jupyter Docker Stacks](https://github.com/jupyter/docker-stacks)
- [Docker Compose GPU support](https://docs.docker.com/compose/how-tos/gpu-support/)
- [Docker Compose bind mounts](https://docs.docker.com/reference/compose-file/services/#volumes)
- [Docker Compose secrets](https://docs.docker.com/reference/compose-file/services/#secrets)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/)
- [PyTorch previous versions](https://pytorch.org/get-started/previous-versions/)
- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Codex configuration reference](https://developers.openai.com/codex/config-reference)
- [Cloudflare Tunnel permissions](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/)
- [Cloudflare Tunnel run parameters](https://developers.cloudflare.com/tunnel/advanced/run-parameters/)
- [Cloudflare Access self-hosted applications](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
- [Tailscale documentation](https://tailscale.com/kb)
