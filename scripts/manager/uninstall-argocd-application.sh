#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG_FILE:?missing KUBECONFIG_FILE}"
: "${APP_NAME:?missing APP_NAME}"
: "${MANIFEST_PATH:?missing MANIFEST_PATH}"

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export KUBECONFIG="$KUBECONFIG_FILE"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/openbao-secret-sync.sh"
# shellcheck disable=SC1091
source "$WORKSPACE_ROOT/scripts/manager/authentik-auth.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

if [[ ! -f "$MANIFEST_PATH" ]]; then
  fail "manifest not found: $MANIFEST_PATH"
fi

platform_app_dir="$WORKSPACE_ROOT/gitops/platform-apps/$APP_NAME"
database_app_dir="$WORKSPACE_ROOT/gitops/databases/$APP_NAME"
needs_authentik_cleanup=false

manifest_kind="$(awk '/^kind:/{print $2; exit}' "$MANIFEST_PATH")"
manifest_name="$(awk '
  $1 == "metadata:" { in_metadata = 1; next }
  in_metadata && $1 == "name:" { print $2; exit }
  in_metadata && $1 !~ /^[[:space:]]/ { in_metadata = 0 }
' "$MANIFEST_PATH")"

application_set_name="${APPLICATION_SET_NAME:-}"
if [[ -z "$application_set_name" && "$manifest_kind" == "ApplicationSet" ]]; then
  application_set_name="${manifest_name:-${APP_NAME}-set}"
fi

delete_authentik_application_by_slug() {
  local application_slug="$1"
  local response application_pk

  response="$(authentik_api_get "/core/applications/?page_size=200")" || return 0
  application_pk="$(
    jq -r \
      --arg application_slug "$application_slug" \
      '.results[]?
        | select((.slug // "") == $application_slug)
        | .pk // .id // .uuid // empty' <<<"$response" | head -n1
  )"

  if [[ -n "$application_pk" ]]; then
    log "Deleting Authentik application ${application_slug}"
    authentik_api_write DELETE "/core/applications/${application_pk}/" >/dev/null || true
  fi
}

delete_authentik_provider_by_name() {
  local provider_name="$1"
  local response provider_pk

  response="$(authentik_api_get "/providers/oauth2/?page_size=200")" || return 0
  provider_pk="$(
    jq -r \
      --arg provider_name "$provider_name" \
      '.results[]?
        | select((.name // "") == $provider_name)
        | .pk // .id // empty' <<<"$response" | head -n1
  )"

  if [[ -n "$provider_pk" ]]; then
    log "Deleting Authentik provider ${provider_name}"
    authentik_api_write DELETE "/providers/oauth2/${provider_pk}/" >/dev/null || true
  fi
}

delete_authentik_scope_mapping() {
  local mapping_name="$1"
  local scope_name="${2:-}"
  local response mapping_pk query

  query="/propertymappings/provider/scope/?page_size=200"
  if [[ -n "$scope_name" ]]; then
    query="/propertymappings/provider/scope/?scope_name=${scope_name}&page_size=200"
  fi

  response="$(authentik_api_get "$query")" || return 0
  mapping_pk="$(
    jq -r \
      --arg mapping_name "$mapping_name" \
      --arg scope_name "$scope_name" \
      '.results[]?
        | select((.name // "") == $mapping_name and (("" == $scope_name) or (.scope_name // "") == $scope_name))
        | .pk // .id // empty' <<<"$response" | head -n1
  )"

  if [[ -n "$mapping_pk" ]]; then
    log "Deleting Authentik scope mapping ${mapping_name}"
    authentik_api_write DELETE "/propertymappings/provider/scope/${mapping_pk}/" >/dev/null || true
  fi
}

delete_authentik_group() {
  local group_name="$1"
  local response group_pk

  response="$(authentik_api_get "/core/groups/?page_size=200")" || return 0
  group_pk="$(
    jq -r \
      --arg group_name "$group_name" \
      '.results[]?
        | select((.name // "") == $group_name)
        | .pk // .id // .uuid // empty' <<<"$response" | head -n1
  )"

  if [[ -n "$group_pk" ]]; then
    log "Deleting Authentik group ${group_name}"
    authentik_api_write DELETE "/core/groups/${group_pk}/" >/dev/null || true
  fi
}

delete_authentik_policy_binding_for_application_group() {
  local application_slug="$1"
  local group_name="$2"
  local app_response group_id binding_pk

  app_response="$(authentik_api_get "/core/applications/?page_size=200")" || return 0
  local target_uuid
  target_uuid="$(
    jq -r \
      --arg application_slug "$application_slug" \
      '.results[]?
        | select((.slug // "") == $application_slug)
        | .pk // .uuid // .id // empty' <<<"$app_response" | head -n1
  )"

  [[ -n "$target_uuid" ]] || return 0

  group_id="$(authentik_find_group_id "$group_name" || true)"
  [[ -n "$group_id" ]] || return 0

  binding_pk="$(
    authentik_api_get "/policies/bindings/?page_size=500" | jq -r \
      --arg target_uuid "$target_uuid" \
      --arg group_id "$group_id" \
      '.results[]?
        | select((.target // "") == $target_uuid and (.group // "") == $group_id)
        | .pk // .id // empty' | head -n1
  )"

  if [[ -n "$binding_pk" ]]; then
    log "Deleting Authentik policy binding for ${application_slug}/${group_name}"
    authentik_api_write DELETE "/policies/bindings/${binding_pk}/" >/dev/null || true
  fi
}

remove_provider_from_embedded_outpost() {
  local provider_name="$1"
  local response provider_pk outpost_id current_providers updated_providers

  response="$(authentik_api_get "/providers/proxy/?page_size=200")" || return 0
  provider_pk="$(
    jq -r \
      --arg provider_name "$provider_name" \
      '.results[]?
        | select((.name // "") == $provider_name)
        | .pk // .id // .uuid // empty' <<<"$response" | head -n1
  )"
  [[ -n "$provider_pk" ]] || return 0

  response="$(authentik_api_get "/outposts/instances/?page_size=100")" || return 0
  outpost_id="$(
    jq -r '.results[]? | select(.name == "authentik Embedded Outpost") | .pk // .id // .uuid // empty' <<<"$response" | head -n1
  )"
  [[ -n "$outpost_id" ]] || return 0

  current_providers="$(
    jq -c --arg outpost_id "$outpost_id" '.results[]? | select((.pk // .id // .uuid // "") == $outpost_id) | .providers // []' <<<"$response"
  )"
  [[ -n "$current_providers" ]] || current_providers="[]"

  updated_providers="$(
    printf '%s\n' "$current_providers" \
      | jq --arg provider_pk "$provider_pk" '
          map(tostring)
          | map(select(. != $provider_pk))
        '
  )"

  if [[ "$current_providers" != "$updated_providers" ]]; then
    log "Removing provider ${provider_name} from the embedded Authentik outpost"
    authentik_api_write PATCH "/outposts/instances/${outpost_id}/" "$(jq -n --argjson providers "$updated_providers" '{providers: $providers}')" >/dev/null
  fi
}

delete_openbao_global_secret() {
  local secret_name="$1"

  if [[ ! -f "${OPENBAO_ROOT_TOKEN_FILE:-}" ]]; then
    return 0
  fi

  local pod root_token
  pod="$(openbao_wait_for_server_pod)"
  openbao_wait_for_unsealed "$pod"
  root_token="$(tr -d '\r\n' <"$OPENBAO_ROOT_TOKEN_FILE")"
  [[ -n "$root_token" ]] || return 0

  log "Deleting OpenBao secret ${secret_name}"
  openbao_exec "$pod" env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$root_token" sh -se <<EOF >/dev/null 2>&1 || true
bao kv delete kv/twinbox/global/${secret_name}
bao kv metadata delete kv/twinbox/global/${secret_name}
EOF
}

cleanup_app_specific_state() {
  case "$APP_NAME" in
    immich)
      delete_authentik_policy_binding_for_application_group "immich" "admins"
      delete_authentik_scope_mapping "Immich role" "profile"
      delete_authentik_provider_by_name "Immich"
      delete_authentik_application_by_slug "immich"
      delete_openbao_global_secret "immich"
      ;;
    nextcloud)
      delete_authentik_scope_mapping "Nextcloud Profile" "profile"
      delete_authentik_scope_mapping "Nextcloud Groups" "groups"
      delete_authentik_provider_by_name "Nextcloud"
      delete_authentik_application_by_slug "nextcloud"
      delete_openbao_global_secret "nextcloud"
      ;;
    audiobookshelf)
      delete_authentik_scope_mapping "Audiobookshelf groups" "groups"
      delete_authentik_provider_by_name "Audiobookshelf"
      delete_authentik_application_by_slug "audiobookshelf"
      delete_openbao_global_secret "audiobookshelf"
      ;;
    karakeep)
      delete_authentik_provider_by_name "Karakeep"
      delete_authentik_application_by_slug "karakeep"
      delete_openbao_global_secret "karakeep"
      ;;
    outline)
      delete_authentik_provider_by_name "Outline"
      delete_authentik_application_by_slug "outline"
      delete_openbao_global_secret "outline"
      ;;
    openwebui)
      delete_authentik_provider_by_name "Open WebUI"
      delete_authentik_application_by_slug "openwebui"
      delete_openbao_global_secret "openwebui"
      ;;
    n8n)
      delete_openbao_global_secret "n8n"
      ;;
    hedgedoc)
      delete_authentik_provider_by_name "HedgeDoc"
      delete_authentik_application_by_slug "hedgedoc"
      delete_openbao_global_secret "hedgedoc"
      ;;
    paperless)
      delete_authentik_provider_by_name "Paperless-ngx"
      delete_authentik_application_by_slug "paperless"
      delete_openbao_global_secret "paperless"
      ;;
    vaultwarden)
      delete_authentik_provider_by_name "Vaultwarden"
      delete_authentik_application_by_slug "vaultwarden"
      delete_openbao_global_secret "vaultwarden"
      ;;
    jitsi)
      delete_authentik_policy_binding_for_application_group "jitsi-openid" "admins"
      delete_authentik_policy_binding_for_application_group "jitsi-openid" "jitsi-hosts"
      delete_authentik_scope_mapping "Jitsi host affiliation" "jitsi"
      delete_authentik_group "jitsi-hosts"
      delete_authentik_provider_by_name "Jitsi broker"
      delete_authentik_application_by_slug "jitsi-openid"
      delete_openbao_global_secret "jitsi-auth"
      ;;
    opencloud)
      delete_authentik_scope_mapping "OpenCloud roles" "roles"
      delete_authentik_provider_by_name "OpenCloud Web"
      delete_authentik_provider_by_name "OpenCloud Desktop"
      delete_authentik_provider_by_name "OpenCloud Android"
      delete_authentik_provider_by_name "OpenCloud iOS"
      delete_authentik_provider_by_name "Cyberduck"
      delete_authentik_application_by_slug "opencloud"
      delete_openbao_global_secret "opencloud"
      ;;
    zulip)
      delete_authentik_provider_by_name "Zulip"
      delete_authentik_application_by_slug "zulip"
      delete_openbao_global_secret "zulip-oidc"
      ;;
    pixelfed)
      delete_authentik_policy_binding_for_application_group "pixelfed" "admins"
      delete_authentik_provider_by_name "Pixelfed"
      delete_authentik_application_by_slug "pixelfed"
      delete_openbao_global_secret "pixelfed"
      ;;
    headlamp)
      delete_authentik_policy_binding_for_application_group "headlamp" "admins"
      delete_authentik_provider_by_name "Headlamp"
      delete_authentik_application_by_slug "headlamp"
      delete_openbao_global_secret "headlamp-oidc"
      ;;
    twinbox-portal)
      delete_authentik_provider_by_name "Twinbox Portal"
      delete_authentik_application_by_slug "twinbox-portal"
      delete_openbao_global_secret "twinbox-portal"
      ;;
  esac
}

case "$APP_NAME" in
  immich|nextcloud|audiobookshelf|karakeep|outline|openwebui|hedgedoc|paperless|vaultwarden|jitsi|opencloud|zulip|pixelfed|headlamp|twinbox-portal)
    needs_authentik_cleanup=true
    ;;
  grafana|loki)
    needs_authentik_cleanup=true
    ;;
esac

log "Deleting Argo CD application ${APP_NAME}"
kubectl delete application "$APP_NAME" -n argocd --cascade --ignore-not-found=true >/dev/null 2>&1 || true
kubectl -n argocd wait --for=delete "application/${APP_NAME}" --timeout=5m >/dev/null 2>&1 || true

if [[ "$manifest_kind" == "ApplicationSet" || -n "$application_set_name" ]]; then
  if [[ -z "$application_set_name" ]]; then
    application_set_name="${manifest_name:-${APP_NAME}-set}"
  fi
  log "Deleting Argo CD applicationset ${application_set_name}"
  kubectl delete applicationset "$application_set_name" -n argocd --cascade --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl -n argocd wait --for=delete "applicationset/${application_set_name}" --timeout=5m >/dev/null 2>&1 || true
fi

if [[ -d "$platform_app_dir" ]]; then
  log "Deleting platform resources from ${platform_app_dir}"
  kubectl delete -k "$platform_app_dir" >/dev/null 2>&1 || true
fi

if [[ -d "$database_app_dir" ]]; then
  log "Deleting database resources from ${database_app_dir}"
  if [[ -f "$database_app_dir/kustomization.yaml" || -f "$database_app_dir/kustomization.yml" ]]; then
    kubectl delete -k "$database_app_dir" >/dev/null 2>&1 || true
  else
    kubectl delete -f "$database_app_dir" >/dev/null 2>&1 || true
  fi
fi

if [[ "$needs_authentik_cleanup" == "true" ]]; then
  authentik_ensure_token
  authentik_setup_forward
fi
cleanup_app_specific_state

case "$APP_NAME" in
  grafana)
    delete_authentik_policy_binding_for_application_group "grafana" "admins"
    delete_authentik_provider_by_name "Grafana"
    delete_authentik_application_by_slug "grafana"
    delete_openbao_global_secret "grafana-oidc"
    ;;
  loki)
    delete_authentik_policy_binding_for_application_group "loki" "admins"
    remove_provider_from_embedded_outpost "Loki"
    delete_authentik_provider_by_name "Loki"
    delete_authentik_application_by_slug "loki"
    ;;
esac

log "App ${APP_NAME} removed"
