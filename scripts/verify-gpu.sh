#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-${repo_root}/.env}"
cd "${repo_root}"
compose=(docker compose --env-file "${env_file}")

"${compose[@]}" exec -T --user jovyan jupyter nvidia-smi
"${compose[@]}" exec -T --user jovyan jupyter python - <<'PY'
import torch

assert torch.cuda.is_available(), "PyTorch CUDA is unavailable"
assert torch.cuda.device_count() >= 1, "No CUDA device is visible"
print(f"PyTorch: {torch.__version__}")
print(f"CUDA runtime: {torch.version.cuda}")
print(f"GPU count: {torch.cuda.device_count()}")
print(f"GPU: {torch.cuda.get_device_name(0)}")
PY
