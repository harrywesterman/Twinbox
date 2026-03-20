FROM node:20-bookworm-slim

ARG TALOSCTL_VERSION=v1.7.4
ARG OPENTOFU_VERSION=v1.8.8
ARG KUBECTL_VERSION=v1.30.0
ARG HELM_VERSION=v3.15.4

WORKDIR /opt/twinbox

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates curl jq tar \
  && curl -fsSL "https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-amd64" -o /tmp/talosctl \
  && curl -fsSL "https://github.com/opentofu/opentofu/releases/download/${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION#v}_linux_amd64.tar.gz" -o /tmp/tofu.tar.gz \
  && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl \
  && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz \
  && tar -xzf /tmp/tofu.tar.gz -C /tmp \
  && tar -xzf /tmp/helm.tar.gz -C /tmp \
  && install -m 0755 /tmp/talosctl /usr/local/bin/talosctl \
  && install -m 0755 /tmp/tofu /usr/local/bin/tofu \
  && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
  && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
  && chmod +x /usr/local/bin/talosctl \
  && chmod +x /usr/local/bin/tofu \
  && chmod +x /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/helm \
  && rm -rf /tmp/talosctl /tmp/tofu /tmp/tofu.tar.gz /tmp/kubectl /tmp/helm.tar.gz /tmp/linux-amd64 \
  && rm -rf /var/lib/apt/lists/*

COPY manager-worker/package.json ./manager-worker/package.json
COPY manager-worker/src ./manager-worker/src
COPY config ./config
COPY infra ./infra
COPY scripts/manager ./scripts/manager

RUN chmod +x ./scripts/manager/*.sh

WORKDIR /opt/twinbox/manager-worker
CMD ["npm", "start"]
