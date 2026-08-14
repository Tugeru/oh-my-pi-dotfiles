#!/usr/bin/env bash
# Static structure checks for oh-my-pi-dotfiles (run locally or in CI).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

failures=0
pass() { printf '  OK  %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; failures=$((failures + 1)); }
warn() { printf '  WARN %s\n' "$*" >&2; }

echo "==> ci-check: $REPO_DIR"

required_paths=(
  install.sh
  agent/config.yml
  agent/models.yml
  agent/packages.list
  auth/auth.json.example
  profiles/full.env
  profiles/minimal.env
  profiles/orca.env
  scripts/doctor.sh
  scripts/sync-from-live.sh
  .gitignore
)
for path in "${required_paths[@]}"; do
  if [[ -e "$path" ]]; then
    pass "exists $path"
  else
    fail "missing $path"
  fi
done

if python3 -c 'import yaml' >/dev/null 2>&1; then
  for file in agent/config.yml agent/models.yml; do
    if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$file" >/dev/null 2>&1; then
      pass "yaml $file"
    else
      fail "invalid yaml $file"
    fi
  done

  python3 - <<'PY' || failures=$((failures + 1))
import re
import sys
from pathlib import Path

import yaml

config = yaml.safe_load(Path("agent/config.yml").read_text()) or {}
models = yaml.safe_load(Path("agent/models.yml").read_text()) or {}
ok = True

def fail(message):
    global ok
    ok = False
    print(f"  FAIL {message}", file=sys.stderr)

def passed(message):
    print(f"  OK  {message}")

roles = config.get("modelRoles")
if not isinstance(roles, dict) or not roles.get("default"):
    fail("config.yml requires modelRoles.default")
else:
    passed("config.yml has modelRoles.default")

theme = config.get("theme")
if not isinstance(theme, dict) or not theme.get("dark") or not theme.get("light"):
    fail("config.yml requires theme.dark and theme.light")
else:
    passed("config.yml has dark and light themes")

providers = models.get("providers")
if not isinstance(providers, dict) or not providers:
    fail("models.yml requires non-empty providers")
else:
    model_count = 0
    for provider_name, provider in providers.items():
        if not isinstance(provider, dict):
            fail(f"provider {provider_name!r} must be an object")
            continue
        entries = provider.get("models")
        if not isinstance(entries, list) or not entries:
            fail(f"provider {provider_name!r} requires models")
            continue
        for entry in entries:
            model_count += 1
            if not isinstance(entry, dict):
                fail(f"provider {provider_name!r} has non-object model")
                continue
            missing = [key for key in ("id", "name", "api") if not entry.get(key)]
            if missing:
                fail(f"provider {provider_name!r} model missing {', '.join(missing)}")
    if model_count:
        passed(f"models.yml has {model_count} model entries")

config_raw = Path("agent/config.yml").read_text()
if "apiKey" in config_raw:
    fail("config.yml must not contain apiKey")
else:
    passed("config.yml has no apiKey")

models_raw = Path("agent/models.yml").read_text()
secretish = re.compile(r"(?:sk-|gho_|ghp_|xai-|AKIA)[A-Za-z0-9_-]{8,}")
if secretish.search(models_raw):
    fail("models.yml appears to contain a real API key")
else:
    passed("models.yml has no obvious embedded API key")

sys.exit(0 if ok else 1)
PY
else
  warn "PyYAML unavailable; skipped YAML validity and shape checks (install with: pip install pyyaml)"
fi

python3 - <<'PY' || failures=$((failures + 1))
import json
import re
import sys
from pathlib import Path

example = json.loads(Path("auth/auth.json.example").read_text())
ok = True

def fail(message):
    global ok
    ok = False
    print(f"  FAIL {message}", file=sys.stderr)

def passed(message):
    print(f"  OK  {message}")

secretish = re.compile(r"^(sk-|gho_|ghp_|xai-|AKIA)[A-Za-z0-9_-]{8,}$")
def walk(value, path="$"):
    if isinstance(value, dict):
        for key, child in value.items():
            walk(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk(child, f"{path}[{index}]")
    elif isinstance(value, str):
        if secretish.match(value):
            fail(f"auth example looks like a real secret at {path}")
        if value != "REPLACE_ME" and len(value) > 20 and " " not in value:
            if path.endswith(".key") or path.endswith(".access") or path.endswith(".refresh"):
                fail(f"auth example has non-placeholder credential at {path}")

walk(example)
passed("auth.json.example has no obvious real secrets")
sys.exit(0 if ok else 1)
PY

while IFS= read -r package || [[ -n "$package" ]]; do
  package="${package#"${package%%[![:space:]]*}"}"
  package="${package%"${package##*[![:space:]]}"}"
  [[ -z "$package" || "$package" == \#* ]] && continue
  if [[ "$package" =~ ^@?[^@[:space:]]+@[^@[:space:]]+$ ]]; then
    pass "pinned plugin $package"
  else
    fail "unpinned or malformed plugin: $package (want name@version)"
  fi
done < agent/packages.list

shopt -s nullglob
extensions=(agent/extensions/*.ts agent/extensions/*.js)
shopt -u nullglob
if [[ ${#extensions[@]} -eq 0 ]]; then
  fail "no extensions under agent/extensions/"
else
  for extension in "${extensions[@]}"; do
    if [[ -s "$extension" ]]; then
      pass "extension $extension"
    else
      fail "empty extension $extension"
    fi
  done
fi

forbidden=(
  auth/auth.json
  agent/auth.json
  agent/sessions
  agent/blobs
  agent/terminal-sessions
  agent/ssh.json
  agent/smithery.json
  agent/package.json
  agent/bun.lock
  agent/node_modules
)
for path in "${forbidden[@]}"; do
  if [[ -e "$path" ]]; then
    fail "forbidden path present in repo worktree: $path"
  else
    pass "absent forbidden $path"
  fi
done

shopt -s nullglob
databases=(agent/*.db agent/*.db-*)
shopt -u nullglob
if [[ ${#databases[@]} -eq 0 ]]; then
  pass "absent forbidden agent database files"
else
  for database in "${databases[@]}"; do
    fail "forbidden database present in repo worktree: $database"
  done
fi

if [[ $(<.gitignore) == *"auth.json"* ]]; then
  pass "gitignore mentions auth.json"
else
  fail "gitignore must mention auth.json"
fi

for script in install.sh scripts/ci-check.sh scripts/doctor.sh scripts/sync-from-live.sh; do
  if [[ -x "$script" ]]; then
    pass "executable $script"
  else
    fail "not executable $script"
  fi
done

(( failures == 0 ))
