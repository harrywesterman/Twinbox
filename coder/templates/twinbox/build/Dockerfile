FROM codercom/enterprise-base:ubuntu

ARG TALOS_VERSION=v1.13.0
ARG KUBECTL_VERSION=v1.36.0
ARG HELM_VERSION=v4.1.4
ARG OPENTOFU_VERSION=v1.11.6
ARG PROTOC_VERSION=30.3
ARG YQ_VERSION=v4.45.2
ARG USER=coder

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        g++ \
        gcc \
        git \
        gnupg \
        jq \
        libssl-dev \
        lsb-release \
        make \
        man-db \
        pkg-config \
        protobuf-compiler \
        python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        silversearcher-ag \
        sudo \
        tmux \
        unzip \
        vim \
        wget \
        zsh \
    && rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64" -o /tmp/talosctl \
    && install -m 0755 /tmp/talosctl /usr/local/bin/talosctl \
    && rm -f /tmp/talosctl

RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl

RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tar.gz /tmp/linux-amd64

RUN curl -fsSL "https://github.com/opentofu/opentofu/releases/download/${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION#v}_linux_amd64.tar.gz" -o /tmp/tofu.tar.gz \
    && tar -xzf /tmp/tofu.tar.gz -C /tmp \
    && install -m 0755 /tmp/tofu /usr/local/bin/tofu \
    && rm -rf /tmp/tofu.tar.gz /tmp/tofu

ENV GO_VERSION=1.24.4 \
    PATH=/usr/local/go/bin:$PATH
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm -f /tmp/go.tar.gz \
    && go version

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl -fsSL "https://sh.rustup.rs" -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --no-modify-path --profile default \
    && rm -f /tmp/rustup-init.sh \
    && rustup component add clippy rustfmt

RUN pip3 install --break-system-packages --no-cache-dir \
        black \
        pytest \
        pytest-cov \
        ruff

ENV NVM_DIR=/usr/local/nvm \
    NODE_VERSION=24
RUN mkdir -p ${NVM_DIR} \
    && curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh" -o /tmp/nvm-install.sh \
    && bash /tmp/nvm-install.sh \
    && rm -f /tmp/nvm-install.sh \
    && . ${NVM_DIR}/nvm.sh \
    && nvm install ${NODE_VERSION} \
    && nvm alias default ${NODE_VERSION} \
    && nvm use default \
    && npm install -g npm@latest

RUN pip3 install --break-system-packages --no-cache-dir \
        ansible-core \
    && ansible --version | head -1

RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

COPY --chmod=755 <<"ENTRY" /usr/local/bin/entrypoint.sh
#!/usr/bin/env bash
set -euo pipefail

. "${NVM_DIR}/nvm.sh"
nvm use default 2>/dev/null || true

exec "$@"
ENTRY

RUN echo "${USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/${USER} \
    && chmod 0440 /etc/sudoers.d/${USER}

USER ${USER}
WORKDIR /home/${USER}

ENV SHELL=/bin/zsh
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN mkdir -p /home/${USER}/Twinbox /home/${USER}/.ssh /home/${USER}/.talos \
    && chmod 700 /home/${USER}/.ssh

EXPOSE 13337
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh"]
