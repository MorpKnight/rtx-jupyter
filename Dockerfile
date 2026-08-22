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

ENTRYPOINT ["tini", "--", "/bin/bash", "-c", "set -e; target_uid=\"$(id -u jovyan)\"; target_gid=\"$(id -g jovyan)\"; mkdir -p \"$CODEX_HOME\"; chown -R \"${target_uid}:${target_gid}\" \"$CODEX_HOME\"; chmod -R u+rwX \"$CODEX_HOME\"; exec gosu jovyan \"$@\"", "--"]
