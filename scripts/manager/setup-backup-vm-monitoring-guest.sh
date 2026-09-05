#!/usr/bin/env bash
set -euo pipefail
version="$1"
beszel="$2"
export DEBIAN_FRONTEND=noninteractive
if ! command -v prometheus-node-exporter >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq prometheus-node-exporter
fi
systemctl enable --now prometheus-node-exporter
if [[ "$beszel" == yes ]]; then
  if [[ ! -x /usr/local/bin/beszel-agent ]] || [[ "$(cat /etc/twinbox-monitoring/version 2>/dev/null || true)" != "$version" ]]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    arch="$(dpkg --print-architecture)"
    asset="beszel-agent_linux_${arch}.tar.gz"
    base="https://github.com/henrygd/beszel/releases/download/v${version}"
    curl -fsSL "$base/$asset" -o "$tmp/$asset"
    curl -fsSL "$base/beszel_${version}_checksums.txt" -o "$tmp/checksums"
    (cd "$tmp" && grep " ${asset}\$" checksums | sha256sum -c -)
    tar -xzf "$tmp/$asset" -C "$tmp" beszel-agent
    install -m 0755 "$tmp/beszel-agent" /usr/local/bin/beszel-agent
    printf '%s' "$version" >/etc/twinbox-monitoring/version
  fi
  id beszel >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin beszel
  cat >/etc/systemd/system/beszel-agent.service <<'UNIT'
[Unit]
Description=Twinbox backup VM Beszel agent
After=network-online.target
Wants=network-online.target
[Service]
User=beszel
ExecStart=/usr/local/bin/beszel-agent
EnvironmentFile=/etc/twinbox-monitoring/agent.env
StateDirectory=beszel-agent
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable beszel-agent
  systemctl restart beszel-agent
  systemctl is-active --quiet beszel-agent
fi
curl -fsS http://127.0.0.1:9100/metrics >/dev/null
