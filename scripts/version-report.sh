#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-${repo_root}/.env}"
image_ref="${IMAGE_REF:-}"

if [[ -z "${image_ref}" && -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
    image_ref="${IMAGE_NAME:-}"
fi

image_ref="${image_ref:-ghcr.io/morpknight/rtx-jupyter:latest}"
cloudflared_image="${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}"

command -v docker >/dev/null 2>&1 || {
    echo "docker is required" >&2
    exit 1
}

printf 'Image reference: %s\n' "${image_ref}"
docker image inspect "${image_ref}" \
    --format 'Image ID: {{.Id}}\nRepo digests: {{json .RepoDigests}}\nCreated: {{.Created}}' 2>/dev/null || true

docker run --rm --entrypoint bash "${image_ref}" -lc '
    set -eu
    printf "OS: "
    . /etc/os-release
    printf "%s %s\n" "$NAME" "$VERSION_ID"
    python --version
    printf "JupyterLab: "
    jupyter lab --version
    python - <<"PY"
import importlib.metadata
import torch

print(f"PyTorch: {torch.__version__}")
print(f"PyTorch CUDA runtime: {torch.version.cuda}")
for package in (
    "transformers",
    "accelerate",
    "safetensors",
    "sentencepiece",
    "huggingface-hub",
):
    print(f"{package}: {importlib.metadata.version(package)}")
PY
    codex --version
    nvtop --version 2>/dev/null | head -n 1 || true
    printf "Installed Python packages:\n"
    python -m pip freeze
'

printf 'cloudflared image: %s\n' "${cloudflared_image}"
docker run --rm "${cloudflared_image}" version
