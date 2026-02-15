# Manager Worker Dockerfile
FROM python:3.11-slim

# Install system dependencies and Kubernetes/Talos CLIs
RUN apt-get update && apt-get install -y \
    gcc \
    libpq-dev \
    git \
    curl \
    ca-certificates \
    apt-transport-https \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update \
    && apt-get install -y kubectl \
    && rm -rf /var/lib/apt/lists/*

# Install talosctl
RUN curl -sL https://talos.dev/installer.sh | sh

# Set working directory
WORKDIR /app

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Worker runs via rq command in docker-compose.yml
CMD ["rq", "worker", "--url", "redis://redis:6379/0", "twinbox"]
