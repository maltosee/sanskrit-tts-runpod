# Dockerfile - build-time installs everything; Node 18 via NodeSource; supervisord for process mgmt.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV HF_HOME=/workspace/huggingface_cache
ENV PYTHONUNBUFFERED=1
WORKDIR /workspace

# System deps (baked)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      apt-utils dos2unix curl ca-certificates build-essential \
      python3 python3-pip python3-venv wget supervisor gnupg2 && \
    rm -rf /var/lib/apt/lists/*

# Install Node 18.x (NodeSource), ensures node & npm versions like v18.x / npm 10.x
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && \
    apt-get update && apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Copy requirements and install python deps
COPY requirements.txt /workspace/requirements.txt
RUN python3 -m pip install --upgrade pip setuptools wheel && \
    pip3 install -r /workspace/requirements.txt && \
    rm -rf /root/.cache/pip

# Copy app code (load_balancer_config.json is included)
COPY . /workspace

# Install node deps only if package.json present
RUN if [ -f package.json ]; then npm ci --no-audit --no-fund; fi

# Provide supervisor config & entrypoint
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /workspace/entrypoint.sh
RUN chmod +x /workspace/entrypoint.sh

# Minimal env adjustments to keep transformers quiet & reduce logs
ENV TRANSFORMERS_VERBOSITY=error
ENV HF_HUB_DISABLE_PROGRESS_BARS=1
ENV TRANSFORMERS_NO_ADVISORY_WARNINGS=1

# Expose ports (Runpod UI screenshot: 80,8888,8889,8000)
EXPOSE 80 8888 8889 8000

CMD ["/workspace/entrypoint.sh"]
