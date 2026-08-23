#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-${repo_root}/.env}"
destination=""
include_data=false
include_codex_state=false
age_recipient=""

usage() {
    cat <<'EOF'
Usage: backup.sh --destination DIR [--include-data]
                 [--include-codex-state --age-recipient RECIPIENT]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --destination)
            destination="${2:?Missing destination}"
            shift 2
            ;;
        --include-data)
            include_data=true
            shift
            ;;
        --include-codex-state)
            include_codex_state=true
            shift
            ;;
        --age-recipient)
            age_recipient="${2:?Missing age recipient}"
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

[[ -n "${destination}" ]] || {
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
install -d -m 0700 "${destination}"
destination="$(realpath "${destination}")"

for source_root in "${workspace_root}" "${data_root}" "${codex_root}"; do
    case "${destination}/" in
        "${source_root}/"|"${source_root}/"*)
            echo "Backup destination must be outside mounted source roots" >&2
            exit 1
            ;;
    esac
done

if [[ "${include_codex_state}" == true ]]; then
    [[ -n "${age_recipient}" ]] || {
        echo "--age-recipient is required with --include-codex-state" >&2
        exit 1
    }
    command -v age >/dev/null 2>&1 || {
        echo "age is required for Codex state backup" >&2
        exit 1
    }
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final_dir="${destination}/rtx-jupyter-backup-${timestamp}"
[[ ! -e "${final_dir}" ]] || {
    echo "Backup already exists: ${final_dir}" >&2
    exit 1
}

staging="$(mktemp -d "${destination}/.rtx-jupyter-backup.XXXXXX")"
checksum_file_list=""
cleanup() {
    if [[ -n "${checksum_file_list}" ]]; then
        rm -f -- "${checksum_file_list}"
    fi
    rm -rf -- "${staging}"
}
trap cleanup EXIT

always_excludes=(
    --exclude=.env
    --exclude='.env.*'
    --exclude=secrets
    --exclude='*/secrets'
    --exclude=cloudflare-tunnel-token
    --exclude='*/cloudflare-tunnel-token'
)

plaintext_excludes=(
    "${always_excludes[@]}"
    --exclude=auth.json
    --exclude='*/auth.json'
    --exclude=.codex
    --exclude='*/.codex'
)

tar -czf "${staging}/workspace.tar.gz" \
    "${plaintext_excludes[@]}" -C "${workspace_root}" .

if [[ "${include_codex_state}" == true ]]; then
    tar -czf - "${always_excludes[@]}" -C "${codex_root}" . \
        | age -r "${age_recipient}" -o "${staging}/codex-state.tar.gz.age"
else
    codex_files=()
    [[ -f "${codex_root}/config.toml" ]] && codex_files+=(config.toml)
    [[ -f "${codex_root}/planner.config.toml" ]] && codex_files+=(planner.config.toml)
    if [[ ${#codex_files[@]} -gt 0 ]]; then
        tar -czf "${staging}/codex-config.tar.gz" \
            -C "${codex_root}" "${codex_files[@]}"
    fi
fi

if [[ "${include_data}" == true ]]; then
    tar -czf "${staging}/data.tar.gz" \
        "${plaintext_excludes[@]}" -C "${data_root}" .
fi

{
    printf 'created_utc=%s\n' "${timestamp}"
    printf 'workspace_included=yes\n'
    printf 'data_included=%s\n' "${include_data}"
    printf 'codex_state_encrypted=%s\n' "${include_codex_state}"
    printf 'format=rtx-jupyter-backup-v1\n'
} >"${staging}/manifest.env"

checksum_file_list="$(mktemp)"
(
    cd "${staging}"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 \
        | sort -z \
        >"${checksum_file_list}"
    xargs -0 sha256sum <"${checksum_file_list}" >SHA256SUMS
)
rm -f -- "${checksum_file_list}"
checksum_file_list=""

chmod -R go-rwx "${staging}"
mv "${staging}" "${final_dir}"
trap - EXIT
echo "Backup created: ${final_dir}"
