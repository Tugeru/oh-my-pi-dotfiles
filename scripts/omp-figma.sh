#!/usr/bin/env bash
# Launch omp with the official Figma MCP server enabled for this run only.
# First use opens Figma OAuth; credentials are managed by OMP, not this repo.
# Usage: scripts/omp-figma.sh [omp args...]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${OMP_AGENT_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}}"
FRAGMENT="$REPO_DIR/agent/mcp.figma.json"
OMP_BIN="${OMP_BIN:-omp}"

[[ -d "$BASE" ]] || { printf 'error: agent dir not found: %s\n' "$BASE" >&2; exit 1; }
[[ -f "$FRAGMENT" ]] || { printf 'error: fragment not found: %s\n' "$FRAGMENT" >&2; exit 1; }
command -v "$OMP_BIN" >/dev/null 2>&1 || { printf 'error: omp binary not found: %s\n' "$OMP_BIN" >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/omp-figma.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

while IFS= read -r -d '' src; do
  name="$(basename "$src")"
  [[ "$name" == "mcp.json" ]] || ln -s "$src" "$STAGE/$name"
done < <(find "$BASE" -mindepth 1 -maxdepth 1 -print0)

BASE_MCP="$BASE/mcp.json" FRAGMENT_MCP="$FRAGMENT" OUT_MCP="$STAGE/mcp.json" python3 - <<'PY'
import json
import os

base_path, frag_path, out_path = (
    os.environ["BASE_MCP"], os.environ["FRAGMENT_MCP"], os.environ["OUT_MCP"]
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
disabled = [s for s in (base.get("disabledServers") or []) if s != "figma"]
if disabled:
    merged["disabledServers"] = disabled
else:
    merged.pop("disabledServers", None)
enabled = sorted(set(base.get("enabledServers") or []) | set(frag.get("enabledServers") or []))
if enabled:
    merged["enabledServers"] = enabled

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
PY

PI_CODING_AGENT_DIR="$STAGE" OMP_AGENT_DIR="$STAGE" "$OMP_BIN" "$@"
