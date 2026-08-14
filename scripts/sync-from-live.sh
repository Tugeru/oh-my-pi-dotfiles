#!/usr/bin/env bash
# Copy managed live omp config back into this repo (allowlisted paths only).
# Use when a managed symlink drifted or to adopt a new extension, agent, or plugin.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OMP_AGENT_DIR="${OMP_AGENT_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}}"
DRY_RUN=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

copy_file() {
  local src="$1"
  local dest="$2"
  [[ -f "$src" ]] || { log "skip missing $src"; return 0; }
  if [[ -L "$src" ]] && [[ "$(readlink "$src")" == "$dest" ]]; then
    log "ok already linked $src"
    return 0
  fi
  log "import $src -> $dest"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest"
}

copy_dir() {
  local src="$1"
  local dest="$2"
  [[ -d "$src" ]] || { log "skip missing $src"; return 0; }
  if [[ -L "$src" ]] && [[ "$(readlink "$src")" == "$dest" ]]; then
    log "ok already linked $src"
    return 0
  fi
  log "import dir $src -> $dest"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest"
}

copy_file "$OMP_AGENT_DIR/config.yml" "$REPO_DIR/agent/config.yml"
copy_file "$OMP_AGENT_DIR/models.yml" "$REPO_DIR/agent/models.yml"

if [[ -d "$OMP_AGENT_DIR/extensions" ]]; then
  shopt -s nullglob
  for extension in "$OMP_AGENT_DIR/extensions"/*; do
    [[ -f "$extension" || -L "$extension" ]] || continue
    name="$(basename "$extension")"
    copy_file "$extension" "$REPO_DIR/agent/extensions/$name"
  done
  shopt -u nullglob
fi

if [[ -d "$OMP_AGENT_DIR/agents" ]]; then
  shopt -s nullglob
  for agent in "$OMP_AGENT_DIR/agents"/*; do
    [[ -d "$agent" || -L "$agent" ]] || continue
    name="$(basename "$agent")"
    dest="$REPO_DIR/agent/agents/$name"
    if [[ -d "$dest" || ! -e "$dest" ]]; then
      copy_dir "$agent" "$dest"
    fi
  done
  shopt -u nullglob
fi

if [[ -f "$OMP_AGENT_DIR/package.json" ]]; then
  log "import plugins $OMP_AGENT_DIR/package.json -> $REPO_DIR/agent/packages.list"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    python3 - "$OMP_AGENT_DIR/package.json" "$REPO_DIR/agent/packages.list" <<'PY'
import json
import sys
from pathlib import Path

package_json = json.loads(Path(sys.argv[1]).read_text())
deps = package_json.get("dependencies") or {}
if not isinstance(deps, dict):
    raise SystemExit("package.json dependencies must be an object")
entries = []
for name, version in sorted(deps.items()):
    if not isinstance(name, str) or not isinstance(version, str):
        continue
    entries.append(f"{name}@{version.lstrip('^~')}")
Path(sys.argv[2]).write_text(
    "# omp plugin install <package> — one pinned entry per line, e.g. name@1.2.3\n"
    + "".join(f"{entry}\n" for entry in entries)
)
PY
  fi
fi

log "done — review with: git -C $REPO_DIR status && git -C $REPO_DIR diff"
log "never commit auth.json, sessions, blobs, databases, or plugin install trees"
