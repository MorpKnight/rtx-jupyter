#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-${repo_root}/.env}"
mode="${1:-pull}"

if [[ "${mode}" != "pull" && "${mode}" != "build" ]]; then
    echo "Usage: $0 [pull|build]" >&2
    exit 2
fi

[[ -f "${env_file}" ]] || {
    echo "Missing environment file: ${env_file}" >&2
    exit 1
}

set -a
# shellcheck disable=SC1090
source "${env_file}"
set +a

cd "${repo_root}"
compose=(docker compose --env-file "${env_file}")
state_root="${UPDATE_STATE_ROOT:-${repo_root}/state/updates}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
record="${state_root}/${timestamp}.txt"
install -d -m 0700 "${state_root}"

{
    printf 'timestamp=%s\n' "${timestamp}"
    printf 'mode=%s\n' "${mode}"
    for service in jupyter cloudflared; do
        container_id="$("${compose[@]}" ps -q "${service}" 2>/dev/null || true)"
        if [[ -n "${container_id}" ]]; then
            printf '%s_container=%s\n' "${service}" "${container_id}"
            image_id="$(docker inspect "${container_id}" --format '{{.Image}}')"
            printf '%s_image_id=%s\n' "${service}" "${image_id}"
            printf '%s_repo_digests=%s\n' "${service}" \
                "$(docker image inspect "${image_id}" --format '{{json .RepoDigests}}')"
        fi
    done
} >"${record}"

"${compose[@]}" config --quiet

if [[ "${mode}" == "build" ]]; then
    if "${compose[@]}" config --services | grep -qx cloudflared; then
        "${compose[@]}" pull cloudflared
    fi
    "${compose[@]}" build --pull --no-cache jupyter
    "${compose[@]}" up -d --force-recreate
else
    "${compose[@]}" pull
    "${compose[@]}" up -d --force-recreate --no-build
fi

"${repo_root}/scripts/verify.sh"
"${repo_root}/scripts/version-report.sh" >"${state_root}/${timestamp}-versions.txt"

echo "Update completed. Previous image IDs and registry digests: ${record}"
echo "Use a recorded jupyter repo digest or image ID as IMAGE_NAME with --no-build for manual rollback."
