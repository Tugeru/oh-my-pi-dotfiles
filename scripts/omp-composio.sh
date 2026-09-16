#!/usr/bin/env bash
# Launch omp with the Composio MCP server enabled for this run only.
#
# OMP has no native `--mcp` flag, and `--config` overlays only carry
# config.yml-style settings, not mcpServers. So this wrapper stages a
# temporary agent dir (symlinks to the live dir plus a merged mcp.json) and
# points OMP at it via PI_CODING_AGENT_DIR. The live mcp.json stays clean.
#
# The fragment is definition-only (no secrets): the consumer key is read from
# $COMPOSIO_CONSUMER_KEY at connect time. Get it from the Composio dashboard
# (For You / Connect) and export it before launching:
#   export COMPOSIO_CONSUMER_KEY='ck_...'
# Google itself connects in-chat on first use ("connect my Google Drive and
# Google Docs accounts") via a short-lived OAuth link; tokens stay with
# Composio and OMP's local credential store, never in this repo.
#
# Usage: scripts/omp-composio.sh [omp args...]
#   e.g. scripts/omp-composio.sh
#   e.g. scripts/omp-composio.sh -p "list the files in my Drive"
#
# Suggested alias: alias ompc='<repo>/scripts/omp-composio.sh'
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${OMP_AGENT_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}}"
FRAGMENT="$REPO_DIR/agent/mcp.composio.json"
OMP_BIN="${OMP_BIN:-omp}"

[[ -d "$BASE" ]] || { printf 'error: agent dir not found: %s\n' "$BASE" >&2; exit 1; }
[[ -f "$FRAGMENT" ]] || { printf 'error: fragment not found: %s\n' "$FRAGMENT" >&2; exit 1; }
[[ -n "${COMPOSIO_CONSUMER_KEY:-}" ]] || {
  printf 'error: COMPOSIO_CONSUMER_KEY is not set (get it from the Composio dashboard, then: export COMPOSIO_CONSUMER_KEY='"'"'ck_...'"'"')\n' >&2
  exit 1
}
command -v "$OMP_BIN" >/dev/null 2>&1 || { printf 'error: omp binary not found: %s\n' "$OMP_BIN" >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/omp-composio.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# Symlink everything; mcp.json gets a merged replacement below.
while IFS= read -r -d '' src; do
  name="$(basename "$src")"
  [[ "$name" == "mcp.json" ]] || ln -s "$src" "$STAGE/$name"
done < <(find "$BASE" -mindepth 1 -maxdepth 1 -print0)

BASE_MCP="$BASE/mcp.json" FRAGMENT_MCP="$FRAGMENT" OUT_MCP="$STAGE/mcp.json" python3 - <<'PY'
import json
import os

base_path, frag_path, out_path = (
    os.environ["BASE_MCP"],
    os.environ["FRAGMENT_MCP"],
    os.environ["OUT_MCP"],
)
try:
    with open(base_path, encoding="utf-8") as f:
        base = json.load(f)
except FileNotFoundError:
    base = {}
with open(frag_path, encoding="utf-8") as f:
    frag = json.load(f)

merged = dict(base)
servers = dict(base.get("mcpServers") or {})
servers.update(frag.get("mcpServers") or {})
merged["mcpServers"] = servers
if "$schema" not in merged and "$schema" in frag:
    merged["$schema"] = frag["$schema"]
# A staged opt-in must never stay behind the user-level denylist.
disabled = [s for s in (base.get("disabledServers") or []) if s != "composio"]
if disabled:
    merged["disabledServers"] = disabled
elif "disabledServers" in merged:
    del merged["disabledServers"]
enabled = sorted(set(base.get("enabledServers") or []) | set(frag.get("enabledServers") or []))
if enabled:
    merged["enabledServers"] = enabled

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
PY

# `exec` would discard the EXIT trap and leak the stage dir; run as a child
# so cleanup always fires, preserving omp's exit code.
PI_CODING_AGENT_DIR="$STAGE" OMP_AGENT_DIR="$STAGE" "$OMP_BIN" "$@"
