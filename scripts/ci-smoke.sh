#!/usr/bin/env bash
set -euo pipefail

image_ref="${1:?Usage: ci-smoke.sh IMAGE_REF}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
container_name="rtx-jupyter-ci-${RANDOM}-${RANDOM}"
cleanup_uid="$(id -u)"
cleanup_gid="$(id -g)"

cleanup() {
    exit_status=$?
    trap - EXIT

    docker rm -f "${container_name}" >/dev/null 2>&1 || true

    # Jupyter's startup intentionally remaps bind-mounted directories to the
    # test UID/GID (1234:1234). Restore runner ownership before deleting the
    # fixture, and never let best-effort cleanup hide the real test result.
    if [[ -d "${tmp_root}" ]]; then
        docker run --rm \
            --user root \
            --entrypoint chown \
            --volume "${tmp_root}:/cleanup" \
            "${image_ref}" \
            -R "${cleanup_uid}:${cleanup_gid}" /cleanup \
            >/dev/null 2>&1 || true
        chmod -R u+rwX "${tmp_root}" >/dev/null 2>&1 || true
        rm -rf -- "${tmp_root}" || true
    fi

    return "${exit_status}"
}
trap cleanup EXIT

mkdir -p \
    "${tmp_root}/workspace" \
    "${tmp_root}/data" \
    "${tmp_root}/codex" \
    "${tmp_root}/secrets"
printf '%s\n' '# preserve-existing-config' >"${tmp_root}/codex/config.toml"
printf '%s\n' 'ci-placeholder-tunnel-token' >"${tmp_root}/secrets/cloudflare-tunnel-token"
chmod 0640 "${tmp_root}/secrets/cloudflare-tunnel-token"

common_env=(
    "COMPOSE_PROJECT_NAME=rtx-jupyter-ci"
    "IMAGE_NAME=${image_ref}"
    "WORKSPACE_ROOT=${tmp_root}/workspace"
    "DATA_ROOT=${tmp_root}/data"
    "CODEX_ROOT=${tmp_root}/codex"
    "JUPYTER_TOKEN=ci-jupyter-token"
    "NB_UID=1234"
    "NB_GID=1234"
)

run_compose_config() {
    env "${common_env[@]}" "$@" docker compose config --format json
}

wait_for_http() {
    local attempts=36
    local container_state
    local host_port

    while ((attempts > 0)); do
        container_state="$(
            docker inspect "${container_name}" \
                --format '{{.State.Status}}' 2>/dev/null || true
        )"
        if [[ "${container_state}" == "exited" || "${container_state}" == "dead" ]]; then
            echo "Container entered terminal state: ${container_state}" >&2
            docker logs "${container_name}" >&2 || true
            return 1
        fi

        # Docker may assign a different ephemeral host port when the container
        # network is recreated, so resolve it again on every attempt.
        host_port="$(
            docker port "${container_name}" 8888/tcp 2>/dev/null \
                | awk -F: 'NR == 1 {print $NF}' || true
        )"
        if [[ -n "${host_port}" ]] \
            && curl --fail --silent \
                "http://127.0.0.1:${host_port}/" >/dev/null; then
            echo "Jupyter HTTP ready on host port ${host_port}."
            return 0
        fi

        sleep 5
        attempts=$((attempts - 1))
    done

    echo "Timed out waiting for Jupyter HTTP endpoint" >&2
    docker inspect "${container_name}" \
        --format 'state={{.State.Status}} ports={{json .NetworkSettings.Ports}}' \
        >&2 || true
    docker logs "${container_name}" >&2 || true
    return 1
}

local_json="$(
    cd "${repo_root}"
    run_compose_config \
        COMPOSE_FILE=compose.yaml:compose.local.yaml \
        JUPYTER_PORT=18888
)"
jq -e '.services | has("jupyter") and (has("cloudflared") | not)' <<<"${local_json}" >/dev/null
jq -e '.services.jupyter.ports[0].host_ip == "127.0.0.1"' <<<"${local_json}" >/dev/null

tailscale_json="$(
    cd "${repo_root}"
    run_compose_config \
        COMPOSE_FILE=compose.yaml:compose.tailscale.yaml \
        TAILSCALE_IP=100.64.0.10
)"
jq -e '.services.jupyter.ports[0].host_ip == "100.64.0.10"' <<<"${tailscale_json}" >/dev/null

cloudflare_json="$(
    cd "${repo_root}"
    run_compose_config \
        COMPOSE_FILE=compose.yaml:compose.cloudflare.yaml \
        CLOUDFLARE_TUNNEL_TOKEN_FILE="${tmp_root}/secrets/cloudflare-tunnel-token"
)"
jq -e '.services | has("jupyter") and has("cloudflared")' <<<"${cloudflare_json}" >/dev/null
jq -e '(.services.jupyter | has("ports")) | not' <<<"${cloudflare_json}" >/dev/null
jq -e '.services.cloudflared.group_add[0] == "1234"' <<<"${cloudflare_json}" >/dev/null

both_json="$(
    cd "${repo_root}"
    run_compose_config \
        COMPOSE_FILE=compose.yaml:compose.tailscale.yaml:compose.cloudflare.yaml:compose.resources.yaml \
        TAILSCALE_IP=100.64.0.10 \
        CLOUDFLARE_TUNNEL_TOKEN_FILE="${tmp_root}/secrets/cloudflare-tunnel-token"
)"
jq -e '.services.jupyter.deploy.resources.reservations.devices[0].driver == "nvidia"' <<<"${both_json}" >/dev/null
jq -e '(.services.jupyter.deploy.resources.limits.memory | tostring) == "34359738368"' <<<"${both_json}" >/dev/null

test "$(jq -r '.name' <<<"${local_json}")" = "rtx-jupyter-ci"
other_name="$(
    cd "${repo_root}"
    env "${common_env[@]}" \
        COMPOSE_PROJECT_NAME=rtx-jupyter-ci-second \
        COMPOSE_FILE=compose.yaml:compose.local.yaml \
        docker compose config --format json \
        | jq -r '.name'
)"
test "${other_name}" = "rtx-jupyter-ci-second"

test "$(docker run --rm --entrypoint id "${image_ref}" -u)" -ne 0

# Match the documented host preparation for pre-existing persistent files.
docker run --rm \
    --user root \
    --entrypoint chown \
    --volume "${tmp_root}/codex:/state" \
    "${image_ref}" \
    1234:1234 /state/config.toml

docker run -d \
    --name "${container_name}" \
    --user root \
    --env NB_UID=1234 \
    --env NB_GID=1234 \
    --env CHOWN_HOME=yes \
    --env CHOWN_EXTRA=/home/jovyan/work,/mnt/data,/home/jovyan/.codex \
    --env JUPYTER_TOKEN=ci-jupyter-token \
    --env CODEX_HOME=/home/jovyan/.codex \
    --volume "${tmp_root}/workspace:/home/jovyan/work" \
    --volume "${tmp_root}/data:/mnt/data" \
    --volume "${tmp_root}/codex:/home/jovyan/.codex" \
    --publish 127.0.0.1::8888 \
    "${image_ref}" >/dev/null

wait_for_http

before_hashes="$(docker exec --user 1234:1234 "${container_name}" \
    sha256sum /home/jovyan/.codex/config.toml /home/jovyan/.codex/planner.config.toml)"

docker exec --user 1234:1234 "${container_name}" bash -lc '
    set -eu
    test "$(id -u)" -eq 1234
    test "$(id -g)" -eq 1234
    test -w /home/jovyan/work
    test -w /mnt/data
    test -w "$CODEX_HOME"
    test -w /home/jovyan/.local/share/jupyter/runtime
    test -w /home/jovyan/.cache
    test -w /home/jovyan/.config
    test ! -w /opt/codex
    test -f "$CODEX_HOME/config.toml"
    test -f "$CODEX_HOME/planner.config.toml"
    test -w "$CODEX_HOME/config.toml"
    test -w "$CODEX_HOME/planner.config.toml"
    grep -q preserve-existing-config "$CODEX_HOME/config.toml"
    grep -q '\''model = "gpt-5.6-sol"'\'' "$CODEX_HOME/planner.config.toml"
    codex --version
    codex-plan --version
    if sudo -n true 2>/dev/null; then
        echo "unexpected sudo access" >&2
        exit 1
    fi
'

docker restart "${container_name}" >/dev/null
wait_for_http

after_hashes="$(docker exec --user 1234:1234 "${container_name}" \
    sha256sum /home/jovyan/.codex/config.toml /home/jovyan/.codex/planner.config.toml)"
test "${before_hashes}" = "${after_hashes}"

echo "CI smoke test passed for ${image_ref}."
