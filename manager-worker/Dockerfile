FROM node:20-bookworm-slim

WORKDIR /opt/twinbox

COPY config ./config

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates curl jq openssl tar xz-utils sudo \
  && . /opt/twinbox/config/pinned-defaults.sh \
  && curl -fsSL "https://github.com/siderolabs/talos/releases/download/${PINNED_TALOS_VERSION}/talosctl-linux-amd64" -o /tmp/talosctl \
  && curl -fsSL "https://github.com/opentofu/opentofu/releases/download/${PINNED_OPENTOFU_VERSION}/tofu_${PINNED_OPENTOFU_VERSION#v}_linux_amd64.tar.gz" -o /tmp/tofu.tar.gz \
  && curl -fsSL "https://dl.k8s.io/release/${PINNED_KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl \
  && curl -fsSL "https://get.helm.sh/helm-${PINNED_HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz \
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
COPY lib ./lib
COPY infra ./infra
COPY scripts/manager ./scripts/manager
COPY scripts/get-talos-image-factory.sh ./scripts/get-talos-image-factory.sh

RUN chmod +x ./scripts/manager/*.sh
RUN chmod +x ./scripts/get-talos-image-factory.sh

WORKDIR /opt/twinbox/manager-worker
CMD ["npm", "start"]
