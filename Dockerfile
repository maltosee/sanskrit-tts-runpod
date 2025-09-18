FROM ubuntu:22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

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
    && rm -rf /var/lib/apt/lists/*

# Create symbolic link for python
RUN ln -s /usr/bin/python3.10 /usr/bin/python

# Set working directory
WORKDIR /workspace

# Upgrade pip
RUN python -m pip install --upgrade pip

# Install PyTorch with CUDA support
RUN pip install torch==2.1.0 torchvision==0.16.0 torchaudio==2.1.0 --index-url https://download.pytorch.org/whl/cu118

# Copy and install requirements
COPY requirements.txt .
RUN pip install -r requirements.txt

# Install parler-tts
RUN pip install git+https://github.com/huggingface/parler-tts.git

# Copy TTS files
COPY runpod_tts_handler.py .
COPY direct_tts_server.py .
COPY start_tts.sh .
RUN chmod +x start_tts.sh

# Expose port
EXPOSE 8888

# Default command
CMD ["python", "direct_tts_server.py"]