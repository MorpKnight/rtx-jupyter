#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${ENV_FILE:-${repo_root}/.env}"
recreate=false

if [[ "${1:-}" == "--recreate" ]]; then
    recreate=true
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--recreate]" >&2
    exit 2
fi

[[ -f "${env_file}" ]] || {
    echo "Missing environment file: ${env_file}" >&2
    exit 1
}

cd "${repo_root}"
compose=(docker compose --env-file "${env_file}")

wait_for_health() {
    container_id="$1"
    service_name="$2"
    attempts=24

    while ((attempts > 0)); do
        health="$(docker inspect "${container_id}" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
        if [[ "${health}" == "healthy" ]]; then
            return 0
        fi
        if [[ "${health}" == "unhealthy" || "${health}" == "exited" || "${health}" == "dead" ]]; then
            echo "${service_name} entered terminal state: ${health}" >&2
            return 1
        fi
        sleep 5
        attempts=$((attempts - 1))
    done

    echo "Timed out waiting for ${service_name} health" >&2
    return 1
}

"${compose[@]}" config --quiet
services="$("${compose[@]}" config --services)"
grep -qx jupyter <<<"${services}"

jupyter_id="$("${compose[@]}" ps -q jupyter)"
[[ -n "${jupyter_id}" ]] || {
    echo "jupyter is not running" >&2
    exit 1
}

wait_for_health "${jupyter_id}" jupyter

before_hashes="$("${compose[@]}" exec -T --user jovyan jupyter \
    sha256sum /home/jovyan/.codex/config.toml /home/jovyan/.codex/planner.config.toml)"

"${compose[@]}" exec -T --user jovyan jupyter bash -lc '
    set -eu
    test "$(id -u)" -ne 0
    test -w /home/jovyan/work
    test -w /mnt/data
    test -w "$CODEX_HOME"
    test -w /home/jovyan/.local/share/jupyter/runtime
    test -w /home/jovyan/.cache
    test -w /home/jovyan/.config
    test ! -e /run/secrets/cloudflare_tunnel_token
    test -f "$CODEX_HOME/config.toml"
    test -f "$CODEX_HOME/planner.config.toml"
    command -v codex
    command -v codex-plan
    codex --version
    codex-plan --version
    curl --fail --silent --show-error http://127.0.0.1:8888/ >/dev/null
    touch /home/jovyan/work/.rtx-jupyter-write-test
    touch /mnt/data/.rtx-jupyter-write-test
    touch "$CODEX_HOME/.rtx-jupyter-write-test"
    rm -f /home/jovyan/work/.rtx-jupyter-write-test \
        /mnt/data/.rtx-jupyter-write-test \
        "$CODEX_HOME/.rtx-jupyter-write-test"
    if sudo -n true 2>/dev/null; then
        echo "unexpected sudo access" >&2
        exit 1
    fi
'

mount_targets="$(docker inspect "${jupyter_id}" --format '{{range .Mounts}}{{println .Destination}}{{end}}')"
grep -qx /home/jovyan/work <<<"${mount_targets}"
grep -qx /mnt/data <<<"${mount_targets}"
grep -qx /home/jovyan/.codex <<<"${mount_targets}"
if grep -qx /run/secrets/cloudflare_tunnel_token <<<"${mount_targets}"; then
    echo "Cloudflare secret unexpectedly mounted in jupyter" >&2
    exit 1
fi

if grep -qx cloudflared <<<"${services}"; then
    cloudflared_id="$("${compose[@]}" ps -q cloudflared)"
    [[ -n "${cloudflared_id}" ]] || {
        echo "cloudflared is enabled but not running" >&2
        exit 1
    }
    wait_for_health "${cloudflared_id}" cloudflared
    docker inspect "${cloudflared_id}" \
        --format '{{range .Mounts}}{{if eq .Destination "/run/secrets/cloudflare_tunnel_token"}}{{if .RW}}writable{{else}}readonly{{end}}{{end}}{{end}}' \
        | grep -qx readonly
    "${compose[@]}" exec -T cloudflared cloudflared version
fi

if [[ "${recreate}" == true ]]; then
    "${compose[@]}" up -d --force-recreate
    jupyter_id="$("${compose[@]}" ps -q jupyter)"
    wait_for_health "${jupyter_id}" jupyter
    after_hashes="$("${compose[@]}" exec -T --user jovyan jupyter \
        sha256sum /home/jovyan/.codex/config.toml /home/jovyan/.codex/planner.config.toml)"
    [[ "${before_hashes}" == "${after_hashes}" ]] || {
        echo "Codex configuration changed after recreate" >&2
        exit 1
    }
fi

echo "RTX Jupyter verification passed."
