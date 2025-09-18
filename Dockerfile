FROM nvidia/cuda:11.8-devel-ubuntu22.04

# Metadata
LABEL maintainer="your-email@domain.com"
LABEL description="Sanskrit TTS Service with Parler-TTS and RunPod"
LABEL version="v1.0"

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV TORCH_CUDA_ARCH_LIST="6.0 6.1 7.0 7.5 8.0 8.6+PTX"
ENV PIP_NO_CACHE_DIR=1

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3.10-dev \
    python3-pip \
    git \
    wget \
    curl \
    build-essential \
    libsndfile1 \
    libsndfile1-dev \
    screen \
    htop \
    nano \
    && rm -rf /var/lib/apt/lists/*

# Create symbolic link for python
RUN ln -s /usr/bin/python3.10 /usr/bin/python

# Set working directory (RunPod Network Volume compatibility)
WORKDIR /workspace

# Upgrade pip
RUN python -m pip install --upgrade pip

# Install PyTorch with CUDA support first (most critical)
RUN pip install torch==2.1.0 torchvision==0.16.0 torchaudio==2.1.0 --index-url https://download.pytorch.org/whl/cu118

# Copy requirements file
COPY requirements.txt .
RUN pip install -r requirements.txt

# Install parler-tts from git (latest version)
RUN pip install git+https://github.com/huggingface/parler-tts.git

# Copy TTS handler files
COPY runpod_tts_handler.py .
COPY direct_tts_server.py .
COPY start_tts.sh .

# Make scripts executable
RUN chmod +x start_tts.sh

# Create health check script
RUN echo '#!/usr/bin/env python3\nimport json\nimport requests\nimport sys\ntry:\n    response = requests.get("http://localhost:8888/health", timeout=5)\n    if response.status_code == 200:\n        print("✅ TTS Service healthy")\n        sys.exit(0)\n    else:\n        print(f"❌ TTS Service unhealthy: {response.status_code}")\n        sys.exit(1)\nexcept Exception as e:\n    print(f"❌ Health check failed: {e}")\n    sys.exit(1)' > /workspace/health_check.py && chmod +x /workspace/health_check.py

# Pre-download model to avoid cold start delays (optional but recommended)
# This adds ~2GB to image but saves 30s on first request
RUN python -c "\
from transformers import AutoTokenizer; \
from parler_tts import ParlerTTSForConditionalGeneration; \
print('Pre-downloading TTS model...'); \
model = ParlerTTSForConditionalGeneration.from_pretrained('ai4bharat/indic-parler-tts'); \
tokenizer = AutoTokenizer.from_pretrained('ai4bharat/indic-parler-tts'); \
print('✅ Model pre-download complete')"

# Expose port
EXPOSE 8888

# Add startup script that handles both direct and serverless modes
RUN echo '#!/bin/bash\necho "🚀 Starting TTS Service..."\necho "Container ID: $(hostname)"\necho "GPU Status:"\nnvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits 2>/dev/null || echo "No GPU detected"\necho "Starting TTS server on port 8888..."\nexec python direct_tts_server.py' > /workspace/entrypoint.sh && chmod +x /workspace/entrypoint.sh

# Health check for container orchestration
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python /workspace/health_check.py || exit 1

# Default command - can be overridden
CMD ["/workspace/entrypoint.sh"]