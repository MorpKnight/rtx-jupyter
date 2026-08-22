FROM quay.io/jupyter/pytorch-notebook:82d322f00937

# Install OS-level tools as root. The entrypoint later drops the service to
# jovyan for runtime.
USER root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gosu \
        nvtop \
    && rm -rf /var/lib/apt/lists/*

# Keep the notebook process unprivileged. This installation is performed in
# the writable default Conda environment provided by the Jupyter image.
USER jovyan

# Install Codex in the image, but keep its account state outside the image.
# CODEX_HOME is bind-mounted by Compose at runtime.
ENV PATH="/home/jovyan/.local/bin:${PATH}" \
    CODEX_HOME="/home/jovyan/.codex"

RUN curl -fsSL https://chatgpt.com/codex/install.sh | sh \
    && command -v codex \
    && codex --version

# The standalone installer keeps the Codex package below CODEX_HOME. Since
# Compose bind-mounts /home/jovyan/.codex for persistent auth/configuration,
# move the installed package outside that mount and recreate the PATH link.
USER root

RUN set -eux; \
    codex_target="$(readlink -f /home/jovyan/.local/bin/codex)"; \
    case "$codex_target" in \
        /home/jovyan/.codex/*) ;; \
        *) echo "Unexpected Codex target: $codex_target" >&2; exit 1 ;; \
    esac; \
    codex_relative="${codex_target#/home/jovyan/.codex/}"; \
    jovyan_uid="$(id -u jovyan)"; \
    jovyan_gid="$(id -g jovyan)"; \
    install -d -o "$jovyan_uid" -g "$jovyan_gid" /opt/codex; \
    cp -a /home/jovyan/.codex/. /opt/codex/; \
    rm -f /home/jovyan/.local/bin/codex; \
    ln -s "/opt/codex/$codex_relative" /home/jovyan/.local/bin/codex; \
    chown -R "$jovyan_uid:$jovyan_gid" /opt/codex /home/jovyan/.local

USER jovyan

RUN command -v codex \
    && codex --version

# Replace the CPU-only PyTorch packages from the base image with CUDA 12.8
# wheels. The NVIDIA driver itself remains on the host and is injected by
# NVIDIA Container Toolkit at runtime.
RUN python -m pip install --no-cache-dir --upgrade --force-reinstall \
        torch==2.8.0 \
        torchvision==0.23.0 \
        torchaudio==2.8.0 \
        --index-url https://download.pytorch.org/whl/cu128

# Dependencies used by the local Qwen/Transformers workflow.
RUN python -m pip install --no-cache-dir \
        transformers \
        accelerate \
        safetensors \
        sentencepiece \
        huggingface_hub

# A bind mount keeps the host directory's ownership. Start the init process
# as root so it can make CODEX_HOME writable, then drop the actual Jupyter
# process back to jovyan. No sudo access is granted to jovyan.
USER root

# Keep defaults outside CODEX_HOME because Compose bind-mounts CODEX_HOME at
# runtime. The entrypoint copies these files only when the host has not
# created them yet, so user changes remain persistent and are never replaced.
RUN install -d -m 0755 /opt/codex-defaults \
    && printf '%s\n' \
        '# Default model for normal chat and execution.' \
        'model = "gpt-5.6-luna"' \
        'model_reasoning_effort = "max"' \
        '# Plan mode keeps high reasoning; the planner profile selects Sol.' \
        'plan_mode_reasoning_effort = "high"' \
        > /opt/codex-defaults/config.toml \
    && printf '%s\n' \
        '# Launch with: codex --profile planner' \
        'model = "gpt-5.6-sol"' \
        'model_reasoning_effort = "high"' \
        'plan_mode_reasoning_effort = "high"' \
        > /opt/codex-defaults/planner.config.toml \
    && chmod 0644 /opt/codex-defaults/*.toml

ENTRYPOINT ["tini", "--", "/bin/bash", "-c", "set -e; target_uid=\"$(id -u jovyan)\"; target_gid=\"$(id -g jovyan)\"; mkdir -p \"$CODEX_HOME\"; if [ ! -e \"$CODEX_HOME/config.toml\" ]; then install -o \"$target_uid\" -g \"$target_gid\" -m 0644 /opt/codex-defaults/config.toml \"$CODEX_HOME/config.toml\"; fi; if [ ! -e \"$CODEX_HOME/planner.config.toml\" ]; then install -o \"$target_uid\" -g \"$target_gid\" -m 0644 /opt/codex-defaults/planner.config.toml \"$CODEX_HOME/planner.config.toml\"; fi; chown -R \"${target_uid}:${target_gid}\" \"$CODEX_HOME\"; chmod -R u+rwX \"$CODEX_HOME\"; exec gosu jovyan \"$@\"", "--"]

CMD ["start-notebook.py"]
