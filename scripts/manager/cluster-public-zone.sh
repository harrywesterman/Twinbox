#!/usr/bin/env bash
set -euo pipefail

twinbox_public_zone_name() {
  local cluster_id="${1:-}"
  local cluster_dns_domain="${2:-}"
  local cluster_id_lower

  cluster_id_lower="$(printf '%s' "$cluster_id" | tr '[:upper:]' '[:lower:]')"

  case "$cluster_id_lower" in
    tst)
      printf 'app.tst.example.org\n'
      return 0
      ;;
    prd)
      printf 'app.example.com\n'
      return 0
      ;;
  esac

  if [[ -n "$cluster_dns_domain" ]]; then
    if [[ "$cluster_dns_domain" == app.* ]]; then
      printf '%s\n' "$cluster_dns_domain"
    else
      printf 'app.%s.%s\n' "$cluster_id_lower" "$cluster_dns_domain"
    fi
    return 0
  fi

  return 1
}
