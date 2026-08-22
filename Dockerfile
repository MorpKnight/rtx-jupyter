FROM quay.io/jupyter/pytorch-notebook:82d322f00937

# Install OS-level tools as root. Runtime privilege dropping is handled by the
# inherited Jupyter Docker Stacks entrypoint.
USER root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        nvtop \
    && rm -rf /var/lib/apt/lists/*

# Keep the notebook process unprivileged. This installation is performed in
# the writable default Conda environment provided by the Jupyter image.
USER jovyan

# Install Codex in the image, but keep its account state outside the image.
# CODEX_HOME is bind-mounted by Compose at runtime.
ENV CODEX_HOME="/home/jovyan/.codex"

RUN curl -fsSL https://chatgpt.com/codex/install.sh | sh \
    && /home/jovyan/.local/bin/codex --version

# The standalone installer keeps the Codex package below CODEX_HOME. Move the
# package into the immutable image so a CODEX_HOME bind mount cannot hide it.
USER root

RUN set -eux; \
    codex_target="$(readlink -f /home/jovyan/.local/bin/codex)"; \
    case "$codex_target" in \
        /home/jovyan/.codex/*) ;; \
        *) echo "Unexpected Codex target: $codex_target" >&2; exit 1 ;; \
    esac; \
    codex_relative="${codex_target#/home/jovyan/.codex/}"; \
    install -d -o root -g root /opt/codex; \
    cp -a /home/jovyan/.codex/. /opt/codex/; \
    rm -f /home/jovyan/.local/bin/codex; \
    ln -s "/opt/codex/$codex_relative" /usr/local/bin/codex; \
    chown -R root:root /opt/codex; \
    chmod -R u+rwX,go-w,a+rX /opt/codex

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

# Keep defaults outside CODEX_HOME because Compose bind-mounts CODEX_HOME at
# runtime. The startup hook seeds missing files only, preserving user changes.
USER root

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
    && chmod 0644 /opt/codex-defaults/*.toml \
    && rm -rf /home/jovyan/.codex

COPY --chown=root:root docker/10-seed-codex-config /usr/local/bin/before-notebook.d/10-seed-codex-config
COPY --chown=root:root docker/codex-plan /usr/local/bin/codex-plan

RUN chmod 0755 \
        /usr/local/bin/before-notebook.d/10-seed-codex-config \
        /usr/local/bin/codex-plan \
    && command -v codex \
    && command -v codex-plan

USER jovyan
CMD ["start-notebook.py"]
