#!/usr/bin/env bash
# Re-apply patched plugin extensions after `omp install` rewrites the plugin
# tree (install.sh runs `omp install` for each pin in agent/packages.list).
#
# Patches:
#   pi-9router-ext@0.2.3 (src/index.ts)
#     Static definitions from the omp models.yml (9router provider) win over
#     the router's bare combo entries, which report no context/output limits
#     and would otherwise fall back to 128K context / 4K output.
#   omniroute-pi-extension@2.2.0 (extensions/omniroute-manager.ts)
#     omp compatibility. Resolve the OmniRoute baseUrl from the `omni` provider
#     in models.yml (on this machine OmniRoute runs on 20129 because 9router
#     owns 20128), and make /omni sync write providers.omni.models back into
#     models.yml (YAML) — omp never reads Pi's models.json.
#
# Guards (per plugin):
#   - no-op when the patch is already applied or the plugin is absent
#   - refuses to patch any version other than the pinned one
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="${OMP_PLUGIN_ROOT:-${XDG_DATA_HOME:-$HOME/.omp}/omp/plugins}"

# name|pinned-version|repo src|plugin-relative target|marker that only exists in the patched file
PATCHES=(
  "pi-9router-ext|0.2.3|agent/patches/pi-9router-ext@0.2.3/index.ts|node_modules/pi-9router-ext/src/index.ts|staticModels = loadStaticModelDefinitions"
  "omniroute-pi-extension|2.2.0|agent/patches/omniroute-pi-extension@2.2.0/extensions/omniroute-manager.ts|node_modules/omniroute-pi-extension/extensions/omniroute-manager.ts|omniProviderBaseUrl"
)

FAILED=0
for spec in "${PATCHES[@]}"; do
  IFS='|' read -r name version src_rel target_rel marker <<< "$spec"
  src="$REPO_DIR/$src_rel"
  target="$PLUGIN_ROOT/$target_rel"
  pkg="$PLUGIN_ROOT/node_modules/$name/package.json"

  if [[ ! -f "$src" ]]; then
    echo "missing patch source: $src" >&2
    FAILED=1
    continue
  fi

  if [[ ! -f "$target" ]]; then
    echo "warn: $name not found at $target — patch not applied" >&2
    continue
  fi

  # Already patched (the marker only exists in the patched file).
  if grep -q "$marker" "$target" 2>/dev/null; then
    echo "ok: $name patch already applied"
    continue
  fi

  if ! grep -q "\"version\": \"$version\"" "$pkg" 2>/dev/null; then
    echo "warn: installed $name is not $version — skipping patch (refresh agent/patches/)" >&2
    continue
  fi

  echo "apply: $name patch ($target)"
  cp -a "$src" "$target"
  echo "done"
done

exit "$FAILED"