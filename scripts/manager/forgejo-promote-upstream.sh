#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$REPO_ROOT/config/pinned-defaults.sh"

log() {
  printf '[forgejo-promote] %s\n' "$1"
}

fail() {
  printf '[forgejo-promote] ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
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

main() {
  if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi

  local upstream_repo_url="${TWINBOX_UPSTREAM_GIT_REPO_URL:-https://github.com/harrywesterman/Twinbox.git}"
  local forgejo_base_url="${FORGEJO_BASE_URL:-http://127.0.0.1:${FORGEJO_HTTP_PORT:-3001}}"
  local forgejo_admin_user="${FORGEJO_ADMIN_USER:-twinbox}"
  local forgejo_admin_password="${FORGEJO_ADMIN_PASSWORD:-}"
  local repo_owner="${TWINBOX_FORGEJO_REPO_OWNER:-$forgejo_admin_user}"
  local repo_name="${TWINBOX_FORGEJO_REPO_NAME:-Twinbox}"
  local target_branch="${TWINBOX_GIT_TARGET_REVISION:-main}"
  local promote_branch="${TWINBOX_FORGEJO_PROMOTION_BRANCH:-forgejo/promotion/upstream-main}"
  local public_repo_url="${TWINBOX_FORGEJO_REPO_URL:-${forgejo_base_url%/}/${repo_owner}/${repo_name}.git}"
  local push_repo_url=""
  local work_dir=""

  require_cmd git
  require_cmd python3

  if [[ -z "$forgejo_admin_password" && -f /opt/twinbox/bootstrap/secrets/global/forgejo.json ]]; then
    forgejo_admin_password="$(python3 - <<'PY'
import json
import pathlib

payload = json.loads(pathlib.Path('/opt/twinbox/bootstrap/secrets/global/forgejo.json').read_text(encoding='utf-8'))
print(payload.get('FORGEJO_ADMIN_PASSWORD', ''))
PY
)"
  fi

  if [[ -z "$forgejo_admin_password" ]]; then
    fail "Forgejo admin password is required"
  fi

  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  git clone --quiet --no-hardlinks "$upstream_repo_url" "$work_dir/repo"
  git -C "$work_dir/repo" fetch --quiet origin "$target_branch"
  git -C "$work_dir/repo" checkout --quiet -B "$promote_branch" "origin/$target_branch"
  git -C "$work_dir/repo" config user.name "Twinbox Forgejo Promotion"
  git -C "$work_dir/repo" config user.email "forgejo@twinbox.local"
  render_repo_placeholders "$work_dir/repo" "$public_repo_url" "$target_branch"
  commit_rendered_changes "$work_dir/repo" "Render Twinbox GitOps sources for Forgejo"

  push_repo_url="$(python3 - "$public_repo_url" "$forgejo_admin_user" "$forgejo_admin_password" <<'PY'
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

  git -C "$work_dir/repo" remote add forgejo "$push_repo_url"
  git -C "$work_dir/repo" push --quiet --force-with-lease forgejo "$promote_branch:refs/heads/$promote_branch"

  log "Pushed promotion branch to Forgejo"
  log "  repository: ${public_repo_url}"
  log "  branch:     ${promote_branch}"
  log "Open a Forgejo PR from ${promote_branch} into ${target_branch} when you are ready to review."
}

main "$@"
