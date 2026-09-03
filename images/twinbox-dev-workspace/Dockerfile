FROM python:3.14-slim-bookworm

ARG TARGETARCH=amd64
ARG CODE_SERVER_VERSION=4.135.0
ARG KUBECTL_VERSION=v1.36.4
ARG HELM_VERSION=v4.2.4
ARG K9S_VERSION=v0.51.0
ARG TALOS_VERSION=v1.13.9
ARG OPENTOFU_VERSION=v1.12.6
ARG OPKSSH_VERSION=0.15.0
ARG OPKSSH_SHA256_AMD64=8fab6eb86031d80da81e87817b3ede39f5cbc0ab0a4a9bf679312732c152d886

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    dnsutils \
    git \
    gnupg \
    iproute2 \
    jq \
    less \
    netcat-openbsd \
    openssh-client \
    procps \
    sudo \
    tini \
    unzip \
    xz-utils \
    zsh \
  && mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
    >/etc/apt/sources.list.d/nodesource.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends nodejs \
  && npm install -g @openai/codex opencode-ai playwright \
  && npx playwright install --with-deps chromium \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    >/etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && curl -fsSL "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${TARGETARCH}.deb" \
    -o /tmp/code-server.deb \
  && apt-get install -y --no-install-recommends /tmp/code-server.deb \
  && rm -f /tmp/code-server.deb \
  && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    -o /usr/local/bin/kubectl \
  && chmod 0755 /usr/local/bin/kubectl \
  && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
    | tar -xz -C /tmp \
  && install -m 0755 "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm \
  && rm -rf "/tmp/linux-${TARGETARCH}" \
  && curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /tmp k9s \
  && install -m 0755 /tmp/k9s /usr/local/bin/k9s \
  && rm -f /tmp/k9s \
  && curl -fsSL "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-${TARGETARCH}" \
    -o /usr/local/bin/talosctl \
  && chmod 0755 /usr/local/bin/talosctl \
  && curl -fsSL "https://github.com/opentofu/opentofu/releases/download/${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION#v}_linux_${TARGETARCH}.zip" \
    -o /tmp/tofu.zip \
  && unzip -q /tmp/tofu.zip -d /tmp/tofu \
  && install -m 0755 /tmp/tofu/tofu /usr/local/bin/tofu \
  && ln -s /usr/local/bin/tofu /usr/local/bin/terraform \
  && rm -rf /tmp/tofu /tmp/tofu.zip \
  && curl -fsSL "https://github.com/openpubkey/opkssh/releases/download/v${OPKSSH_VERSION}/opkssh-linux-${TARGETARCH}" \
    -o /tmp/opkssh \
  && case "${TARGETARCH}" in \
    amd64) opkssh_sha256="${OPKSSH_SHA256_AMD64}" ;; \
    *) echo "Missing pinned opkssh checksum for TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
  esac \
  && echo "${opkssh_sha256}  /tmp/opkssh" | sha256sum -c - \
  && install -m 0755 /tmp/opkssh /usr/local/bin/opkssh \
  && rm -f /tmp/opkssh \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 coder \
  && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash coder \
  && echo "coder ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/coder \
  && chmod 0440 /etc/sudoers.d/coder \
  && mkdir -p /workspace /ms-playwright \
  && chown -R coder:coder /home/coder /workspace /ms-playwright

COPY bin/tb /usr/local/bin/tb
COPY bin/twinbox-dev-startup /usr/local/bin/twinbox-dev-startup
COPY bin/twinbox-ssh-login /usr/local/bin/twinbox-ssh-login
COPY skills /opt/twinbox-agent-skills

RUN chmod 0755 /usr/local/bin/tb /usr/local/bin/twinbox-dev-startup /usr/local/bin/twinbox-ssh-login \
  && mkdir -p /home/coder/code /opt/twinbox-opkssh \
  && chown -R coder:coder /home/coder /workspace /ms-playwright /opt/twinbox-agent-skills

USER coder
WORKDIR /home/coder

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sleep", "infinity"]
