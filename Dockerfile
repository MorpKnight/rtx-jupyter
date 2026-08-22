FROM quay.io/jupyter/pytorch-notebook:82d322f00937

# Install OS-level tools as root. The container returns to jovyan for runtime.
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
ENV PATH="/home/jovyan/.local/bin:${PATH}" \
    CODEX_HOME="/home/jovyan/.codex"

RUN curl -fsSL https://chatgpt.com/codex/install.sh | sh \
    && command -v codex \
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
