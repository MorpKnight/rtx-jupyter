#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-${repo_root}/.env}"
backup_dir=""
age_identity=""

usage() {
    cat <<'EOF'
Usage: restore.sh --backup DIR [--age-identity PRIVATE_KEY_FILE]

All destination directories must already exist and be empty.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup)
            backup_dir="${2:?Missing backup directory}"
            shift 2
            ;;
        --age-identity)
            age_identity="${2:?Missing age identity file}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "${backup_dir}" ]] || {
    usage >&2
    exit 2
}
[[ -f "${env_file}" ]] || {
    echo "Missing environment file: ${env_file}" >&2
    exit 1
}

set -a
# shellcheck disable=SC1090
source "${env_file}"
set +a

backup_dir="$(realpath "${backup_dir}")"

resolve_configured_path() {
    configured_path="$1"
    case "${configured_path}" in
        /*) realpath "${configured_path}" ;;
        *) realpath "${repo_root}/${configured_path}" ;;
    esac
}

workspace_root="$(resolve_configured_path "${WORKSPACE_ROOT:-workspace}")"
data_root="$(resolve_configured_path "${DATA_ROOT:-data}")"
codex_root="$(resolve_configured_path "${CODEX_ROOT:-state/codex}")"

[[ -f "${backup_dir}/manifest.env" && -f "${backup_dir}/SHA256SUMS" ]] || {
    echo "Invalid backup directory" >&2
    exit 1
}

(
    cd "${backup_dir}"
    sha256sum --check SHA256SUMS
)

require_empty_directory() {
    path="$1"
    [[ -d "${path}" ]] || {
        echo "Restore target does not exist: ${path}" >&2
        exit 1
    }
    if find "${path}" -mindepth 1 -print -quit | grep -q .; then
        echo "Restore target is not empty: ${path}" >&2
        exit 1
    fi
}

require_empty_directory "${workspace_root}"

if [[ -f "${backup_dir}/data.tar.gz" ]]; then
    require_empty_directory "${data_root}"
fi

if [[ -f "${backup_dir}/codex-config.tar.gz" || -f "${backup_dir}/codex-state.tar.gz.age" ]]; then
    require_empty_directory "${codex_root}"
fi

if [[ -f "${backup_dir}/codex-state.tar.gz.age" ]]; then
    [[ -n "${age_identity}" ]] || {
        echo "--age-identity is required for encrypted Codex state" >&2
        exit 1
    }
    command -v age >/dev/null 2>&1 || {
        echo "age is required for encrypted Codex state restore" >&2
        exit 1
    }
    age --decrypt -i "${age_identity}" "${backup_dir}/codex-state.tar.gz.age" \
        | tar -tzf - >/dev/null
fi

tar -xzf "${backup_dir}/workspace.tar.gz" -C "${workspace_root}"

if [[ -f "${backup_dir}/data.tar.gz" ]]; then
    tar -xzf "${backup_dir}/data.tar.gz" -C "${data_root}"
fi

if [[ -f "${backup_dir}/codex-config.tar.gz" ]]; then
    tar -xzf "${backup_dir}/codex-config.tar.gz" -C "${codex_root}"
fi

if [[ -f "${backup_dir}/codex-state.tar.gz.age" ]]; then
    age --decrypt -i "${age_identity}" "${backup_dir}/codex-state.tar.gz.age" \
        | tar -xzf - -C "${codex_root}"
fi

echo "Restore completed. Review ownership before starting containers."
