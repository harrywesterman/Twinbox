#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$REPO_ROOT/config/pinned-defaults.sh"

log() {
  printf '[forgejo-bootstrap] %s\n' "$1"
}

fail() {
  printf '[forgejo-bootstrap] ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

upsert_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (updated == 0) {
        print key "=" value
      }
    }
  ' "$file" >"$tmp_file"
  mv "$tmp_file" "$file"
}

wait_for_forgejo() {
  local base_url="$1"
  local attempt=1
  local attempts=120

  while [[ "$attempt" -le "$attempts" ]]; do
    if curl -fsSI "$base_url" >/dev/null 2>&1; then
      return 0
    fi

    log "Waiting for Forgejo at ${base_url} (${attempt}/${attempts})"
    sleep 2
    attempt=$((attempt + 1))
  done

  fail "Forgejo never became reachable at ${base_url}"
}

ensure_secret_file() {
  local secret_dir="$1"
  local secret_file="$2"
  local admin_user="$3"
  local admin_email="$4"
  local admin_password="$5"
  local base_url="$6"
  local generated_password=""

  install -d -m 0700 "$secret_dir"

  if [[ -f "$secret_file" ]]; then
    admin_user="$(python3 - "$secret_file" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload.get("FORGEJO_ADMIN_USER", ""))
PY
)"
    admin_email="$(python3 - "$secret_file" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload.get("FORGEJO_ADMIN_EMAIL", ""))
PY
)"
    admin_password="$(python3 - "$secret_file" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload.get("FORGEJO_ADMIN_PASSWORD", ""))
PY
)"
    base_url="$(python3 - "$secret_file" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload.get("FORGEJO_BASE_URL", ""))
PY
)"
  else
    if [[ -z "$admin_password" ]]; then
      generated_password="$(openssl rand -base64 32 | tr -d '\n')"
      admin_password="$generated_password"
    fi

    python3 - "$secret_file" "$admin_user" "$admin_email" "$admin_password" "$base_url" <<'PY'
import json
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
payload = {
    "FORGEJO_ADMIN_USER": sys.argv[2],
    "FORGEJO_ADMIN_EMAIL": sys.argv[3],
    "FORGEJO_ADMIN_PASSWORD": sys.argv[4],
    "FORGEJO_BASE_URL": sys.argv[5],
}
target.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
target.chmod(0o600)
PY
  fi

  export FORGEJO_ADMIN_USER="$admin_user"
  export FORGEJO_ADMIN_EMAIL="$admin_email"
  export FORGEJO_ADMIN_PASSWORD="$admin_password"
  export FORGEJO_BASE_URL="$base_url"
}

ensure_admin_user() {
  local create_output=""

  if docker compose exec -T forgejo sh -lc "forgejo admin user list --admin | grep -Fq '${FORGEJO_ADMIN_USER}'" >/dev/null 2>&1; then
    log "Forgejo admin user already exists: ${FORGEJO_ADMIN_USER}"
    return 0
  fi

  log "Creating Forgejo admin user: ${FORGEJO_ADMIN_USER}"
  if ! create_output="$(docker compose exec -T forgejo sh -lc \
    "forgejo admin user create --username '${FORGEJO_ADMIN_USER}' --password '${FORGEJO_ADMIN_PASSWORD}' --email '${FORGEJO_ADMIN_EMAIL}' --admin --must-change-password=false" 2>&1)"; then
    if grep -qiE 'already exists|is already taken|user exists' <<<"$create_output"; then
      log "Forgejo admin user already exists: ${FORGEJO_ADMIN_USER}"
      return 0
    fi
    printf '%s\n' "$create_output" >&2
    fail "Failed to create Forgejo admin user"
  fi
}

render_repo_placeholders() {
  local checkout_dir="$1"
  local repo_url="$2"
  local target_revision="$3"

  python3 - "$checkout_dir" "$repo_url" "$target_revision" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
repo_url = sys.argv[2]
target_revision = sys.argv[3]
github_repo_url = "https://github.com/harrywesterman/Twinbox.git"
main_revision_re = re.compile(r"^(\s*(?:-\s*)?targetRevision:\s*)main(\s*(?:#.*)?)$")


def split_newline(line):
    if line.endswith("\r\n"):
        return line[:-2], "\r\n"
    if line.endswith("\n"):
        return line[:-1], "\n"
    return line, ""


def render_text(text):
    lines = text.splitlines(keepends=True)
    rendered = []
    pending_twinbox_revision = False

    for raw_line in lines:
        line = raw_line
        is_twinbox_repo_line = "__REPO_URL__" in line or github_repo_url in line

        if "repoURL:" in line and not is_twinbox_repo_line:
            pending_twinbox_revision = False

        if "__REPO_URL__" in line:
            line = line.replace("__REPO_URL__", repo_url)
        if "__TARGET_REVISION__" in line:
            line = line.replace("__TARGET_REVISION__", target_revision)

        if github_repo_url in line:
            line = line.replace(github_repo_url, repo_url)
            pending_twinbox_revision = True

        if pending_twinbox_revision:
            body, newline = split_newline(line)
            match = main_revision_re.match(body)
            if match:
                line = f"{match.group(1)}{target_revision}{match.group(2)}{newline}"
                pending_twinbox_revision = False
            elif "targetRevision:" in line:
                pending_twinbox_revision = False

        rendered.append(line)

    return "".join(rendered)


for path in root.rglob("*"):
    if not path.is_file():
        continue
    if path.suffix not in {".yaml", ".yml"}:
        continue
    text = path.read_text(encoding="utf-8")
    rendered = render_text(text)
    if rendered != text:
        path.write_text(rendered, encoding="utf-8")
PY
}

commit_rendered_changes() {
  local repo_dir="$1"
  local message="$2"

  git -C "$repo_dir" add -A
  if git -C "$repo_dir" diff --cached --quiet; then
    return 0
  fi

  git -C "$repo_dir" commit --quiet -m "$message"
}

resolve_seed_source() {
  local upstream_repo_url="${TWINBOX_UPSTREAM_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}"
  local local_seed_dir="${TWINBOX_FORGEJO_SEED_SOURCE_DIR:-}"

  if [[ -n "$local_seed_dir" ]]; then
    if git -C "$local_seed_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      printf '%s\n' "$local_seed_dir"
      return 0
    fi

    fail "TWINBOX_FORGEJO_SEED_SOURCE_DIR is not a Git repository: ${local_seed_dir}"
  fi

  printf '%s\n' "$upstream_repo_url"
}

clone_seed_source() {
  local seed_source="$1"
  local destination="$2"

  if git -C "$seed_source" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git clone --quiet --no-hardlinks "$seed_source" "$destination"
  else
    git clone --quiet "$seed_source" "$destination"
  fi
}

seed_repo_if_needed() {
  local seed_source="$1"
  local public_repo_url="$2"
  local push_repo_url="$3"
  local target_branch="$4"
  local checkout_dir=""
  local remote_ref=""

  if git ls-remote --exit-code "$public_repo_url" "refs/heads/${target_branch}" >/dev/null 2>&1; then
    log "Forgejo repo already has ${target_branch}: ${public_repo_url}"
    return 0
  fi

  checkout_dir="$(mktemp -d "${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}/state/forgejo/seed.XXXXXX")"
  trap 'rm -rf "$checkout_dir"' EXIT
  clone_seed_source "$seed_source" "$checkout_dir/repo"
  if git -C "$checkout_dir/repo" show-ref --verify --quiet "refs/remotes/origin/${target_branch}"; then
    git -C "$checkout_dir/repo" checkout --quiet -B "$target_branch" "origin/${target_branch}"
  elif git -C "$checkout_dir/repo" show-ref --verify --quiet "refs/heads/${target_branch}"; then
    git -C "$checkout_dir/repo" checkout --quiet "$target_branch"
  fi
  git -C "$checkout_dir/repo" config user.name "Twinbox Forgejo Bootstrap"
  git -C "$checkout_dir/repo" config user.email "forgejo@twinbox.local"
  render_repo_placeholders "$checkout_dir/repo" "$public_repo_url" "$target_branch"
  commit_rendered_changes "$checkout_dir/repo" "Render Twinbox GitOps sources for Forgejo"
  git -C "$checkout_dir/repo" remote add forgejo "$push_repo_url"
  git -C "$checkout_dir/repo" push --quiet forgejo "HEAD:refs/heads/${target_branch}"

  remote_ref="$(git -C "$checkout_dir/repo" ls-remote --heads forgejo "$target_branch" | awk '{print $1}' | head -n1)"
  [[ -n "$remote_ref" ]] || fail "Forgejo seed push did not create ${target_branch}"
  log "Seeded Forgejo repo at ${public_repo_url}"
}

ensure_repo_url_in_env() {
  local env_file="$1"
  local repo_url="$2"
  local target_branch="$3"

  if [[ ! -f "$env_file" ]]; then
    fail "Environment file not found: ${env_file}"
  fi

  upsert_env_value "$env_file" "TWINBOX_GIT_REPO_URL" "$repo_url"
  upsert_env_value "$env_file" "TWINBOX_GIT_TARGET_REVISION" "$target_branch"
}

main() {
  if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi

  local forgejo_port="${FORGEJO_HTTP_PORT:-3001}"
  local base_url="${FORGEJO_BASE_URL:-http://127.0.0.1:${forgejo_port}}"
  local admin_user="${FORGEJO_ADMIN_USER:-twinbox}"
  local admin_email="${FORGEJO_ADMIN_EMAIL:-admin@twinbox.local}"
  local admin_password="${FORGEJO_ADMIN_PASSWORD:-}"
  local repo_owner="${TWINBOX_FORGEJO_REPO_OWNER:-$admin_user}"
  local repo_name="${TWINBOX_FORGEJO_REPO_NAME:-Twinbox}"
  local target_branch="${TWINBOX_GIT_TARGET_REVISION:-main}"
  local public_repo_url="${TWINBOX_FORGEJO_REPO_URL:-${base_url%/}/${repo_owner}/${repo_name}.git}"
  local bootstrap_dir="${TWINBOX_BOOTSTRAP_DIR:-/opt/twinbox/bootstrap}"
  local secret_dir="${bootstrap_dir}/secrets/global"
  local state_dir="${bootstrap_dir}/state/forgejo"
  local secret_file="${secret_dir}/forgejo.json"
  local push_repo_url=""
  local seed_source=""

  require_cmd curl
  require_cmd docker
  require_cmd git
  require_cmd python3
  require_cmd openssl
  require_cmd install
  install -d -m 0700 "$state_dir"

  ensure_secret_file "$secret_dir" "$secret_file" "$admin_user" "$admin_email" "$admin_password" "$base_url"
  wait_for_forgejo "$base_url"
  ensure_admin_user

  push_repo_url="$(python3 - "$public_repo_url" "$FORGEJO_ADMIN_USER" "$FORGEJO_ADMIN_PASSWORD" <<'PY'
import os
import sys
from urllib.parse import quote, urlsplit, urlunsplit

repo_url = sys.argv[1]
username = quote(sys.argv[2], safe="")
password = quote(sys.argv[3], safe="")
parts = urlsplit(repo_url)
netloc = f"{username}:{password}@{parts.hostname}"
if parts.port:
    netloc = f"{netloc}:{parts.port}"
print(urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment)))
PY
)"

  seed_source="$(resolve_seed_source)"
  seed_repo_if_needed "$seed_source" "$public_repo_url" "$push_repo_url" "$target_branch"
  ensure_repo_url_in_env "$REPO_ROOT/.env" "$public_repo_url" "$target_branch"

  log "Forgejo bootstrap complete"
  log "Forgejo repo URL: ${public_repo_url}"
  log "Target revision: ${target_branch}"
}

main "$@"
