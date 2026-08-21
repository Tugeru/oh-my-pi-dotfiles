#!/usr/bin/env bash
# Patch the OMP 17.4 bundled OpenAI-completions parser for Muse Spark.
# The OpenCode Free route ends with [DONE] but omits choice.finish_reason.
set -euo pipefail

EXPECTED_OMP_VERSION="17.4.0"
MARKER="omp-muse-spark-finish-compat"

resolve_omp_bundle() {
  local omp_bin
  omp_bin="${OMP_BIN:-$(command -v omp || true)}"
  [[ -n "$omp_bin" ]] || return 1
  readlink -f "$omp_bin"
}

bundle="$(resolve_omp_bundle || true)"
if [[ -z "$bundle" || ! -f "$bundle" ]]; then
  echo "warn: omp bundle not found — Muse Spark patch not applied" >&2
  exit 0
fi

package_json="$(dirname "$(dirname "$bundle")")/package.json"
if [[ ! -f "$package_json" ]] || ! grep -q '"version": "17\.4\.0"' "$package_json"; then
  echo "warn: OMP bundle is not pinned to ${EXPECTED_OMP_VERSION} — skipping Muse Spark patch" >&2
  exit 0
fi

if grep -q "$MARKER" "$bundle"; then
  echo "ok: OMP Muse Spark finish compatibility already applied"
  exit 0
fi

python3 - "$bundle" "$MARKER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text()
old = 'if(vs===void 0&&r.content.length>0)throw new po("OpenAI completions stream closed before a finish_reason was received",{provider:e.provider,kind:"incomplete-stream"});'
new = ('/*' + marker + '*/if(vs===void 0&&r.content.length>0){'
       'if(e.provider==="9router"&&e.id==="oc/muse-spark-1.2-contributor-free")'
       'r.stopReason=r.content.some((We)=>We.type==="toolCall")?"toolUse":"stop";'
       'else throw new po("OpenAI completions stream closed before a finish_reason was received",'
       '{provider:e.provider,kind:"incomplete-stream"});}')
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected one OMP finish-reason throw, found {count}")
path.write_text(text.replace(old, new))
PY

echo "apply: OMP Muse Spark finish compatibility ($bundle)"
echo "done"
