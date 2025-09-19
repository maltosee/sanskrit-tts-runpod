# ----------------------------------------------------------------------
# Dockerfile: Clean, production-ready TTS + Load Balancer container
# ----------------------------------------------------------------------
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV HF_HOME=/workspace/huggingface_cache
ENV PYTHONUNBUFFERED=1
WORKDIR /workspace

# ----------------------------------------------------------------------
# System dependencies (baked in)
# ----------------------------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      apt-utils dos2unix curl ca-certificates build-essential \
      python3 python3-pip python3-venv wget gnupg2 git && \
    rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------
# Install Node 18/npm (latest NodeSource build, not Ubuntu repo)
# ----------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && \
    apt-get update && apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------
# Python dependencies
# ----------------------------------------------------------------------
COPY requirements.txt /workspace/requirements.txt
RUN python3 -m pip install --upgrade pip setuptools wheel && \
    pip3 install --no-cache-dir -r /workspace/requirements.txt && \
    rm -rf /root/.cache/pip

# ----------------------------------------------------------------------
# Application code
# ----------------------------------------------------------------------
COPY . /workspace

# Install Node dependencies if package.json exists
RUN if [ -f package.json ]; then npm ci --no-audit --no-fund; fi

# ----------------------------------------------------------------------
# entrypoint
# ----------------------------------------------------------------------
COPY entrypoint.sh /workspace/entrypoint.sh
RUN chmod +x /workspace/entrypoint.sh

# ----------------------------------------------------------------------
# Minimize logs (HF + Transformers)
# ----------------------------------------------------------------------
ENV TRANSFORMERS_VERBOSITY=error
ENV HF_HUB_DISABLE_PROGRESS_BARS=1
ENV TRANSFORMERS_NO_ADVISORY_WARNINGS=1

# ----------------------------------------------------------------------
# Ports exposed: LB (80) + TTS workers (8888, 8889, 8000)
# ----------------------------------------------------------------------
EXPOSE 80 8888 8889 8000

# ----------------------------------------------------------------------
# Default command: orchestrator entrypoint
# ----------------------------------------------------------------------
CMD ["/workspace/entrypoint.sh"]
