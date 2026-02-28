FROM node:20-bookworm-slim

ARG TALOSCTL_VERSION=v1.7.4

WORKDIR /opt/twinbox

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates curl jq \
  && curl -fsSL "https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-amd64" -o /usr/local/bin/talosctl \
  && chmod +x /usr/local/bin/talosctl \
  && rm -rf /var/lib/apt/lists/*

COPY manager-worker/package.json ./manager-worker/package.json
COPY manager-worker/src ./manager-worker/src
COPY scripts/manager ./scripts/manager

RUN chmod +x ./scripts/manager/*.sh

WORKDIR /opt/twinbox/manager-worker
CMD ["npm", "start"]
