FROM node:26-alpine

WORKDIR /opt/twinbox

COPY config ./config
COPY docker-compose.yml ./docker-compose.yml

RUN apk update \
  && apk add --no-cache bash ca-certificates coreutils curl docker-cli docker-cli-compose iptables jq iproute2 netcat-openbsd openssh-client openssl python3 tar xorriso xz sudo \
  && . /opt/twinbox/config/pinned-defaults.sh \
  && curl -fsSL "https://github.com/siderolabs/talos/releases/download/${PINNED_TALOS_VERSION}/talosctl-linux-amd64" -o /tmp/talosctl \
  && curl -fsSL "https://github.com/opentofu/opentofu/releases/download/${PINNED_OPENTOFU_VERSION}/tofu_${PINNED_OPENTOFU_VERSION#v}_linux_amd64.tar.gz" -o /tmp/tofu.tar.gz \
  && curl -fsSL "https://dl.k8s.io/release/${PINNED_KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl \
  && curl -fsSL "https://get.helm.sh/helm-${PINNED_HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz \
  && curl -fsSL "https://github.com/coder/coder/releases/download/v${PINNED_CODER_CHART_VERSION}/coder_${PINNED_CODER_CHART_VERSION}_linux_amd64.tar.gz" -o /tmp/coder.tar.gz \
  && curl -fsSL "https://github.com/coder/coder/releases/download/v${PINNED_CODER_CHART_VERSION}/coder_${PINNED_CODER_CHART_VERSION}_checksums.txt" -o /tmp/coder_checksums.txt \
  && coder_sha256="$(awk -v file="coder_${PINNED_CODER_CHART_VERSION}_linux_amd64.tar.gz" '$2 == file {print $1}' /tmp/coder_checksums.txt)" \
  && echo "${coder_sha256}  /tmp/coder.tar.gz" | sha256sum -c - \
  && tar -xzf /tmp/tofu.tar.gz -C /tmp \
  && tar -xzf /tmp/helm.tar.gz -C /tmp \
  && tar -xzf /tmp/coder.tar.gz -C /tmp coder \
  && install -m 0755 /tmp/talosctl /usr/local/bin/talosctl \
  && install -m 0755 /tmp/tofu /usr/local/bin/tofu \
  && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
  && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
  && install -m 0755 /tmp/coder /usr/local/bin/coder \
  && chmod +x /usr/local/bin/talosctl \
  && chmod +x /usr/local/bin/tofu \
  && chmod +x /usr/local/bin/kubectl \
  && chmod +x /usr/local/bin/helm \
  && chmod +x /usr/local/bin/coder \
  && rm -rf /tmp/talosctl /tmp/tofu /tmp/tofu.tar.gz /tmp/kubectl /tmp/helm.tar.gz /tmp/linux-amd64 /tmp/coder /tmp/coder.tar.gz /tmp/coder_checksums.txt

COPY manager-worker/package.json ./manager-worker/package.json
COPY manager-worker/package-lock.json ./manager-worker/package-lock.json
RUN cd /opt/twinbox/manager-worker && npm ci --omit=dev

COPY manager-worker/src ./manager-worker/src
COPY lib ./lib
COPY categories ./categories
COPY infra ./infra
COPY gitops ./gitops
COPY scripts/manager ./scripts/manager
COPY scripts/get-talos-image-factory.sh ./scripts/get-talos-image-factory.sh
COPY manager-web/src/assets/step-icons ./manager-web/src/assets/step-icons

RUN cd /opt/twinbox/categories/apps/steps/install-nextcloud/eurooffice-file-action \
  && npm ci \
  && npm run build \
  && rm -rf node_modules

RUN chmod +x ./scripts/manager/*.sh
RUN chmod +x ./scripts/get-talos-image-factory.sh

WORKDIR /opt/twinbox/manager-worker
CMD ["npm", "start"]
