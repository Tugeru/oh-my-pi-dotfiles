#!/usr/bin/env bash
# Install omp dotfiles: config, models, extensions, optional agents, and plugins.
# Safe defaults: never overwrites auth.json or runtime data.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="symlink" # symlink | copy
PROFILE="full" # full | minimal | orca
DRY_RUN=0
CHANGES=0
UNCHANGED=0
PKGS=0
SKIP_PACKAGES=0
WITH_ORCA=1
ORCA_SET=0
INSTALL_EXTENSIONS=1
INSTALL_PACKAGES=1
INSTALL_OMP=0
DOCTOR_ONLY=0
FORCE=0

# OMP natively honors PI_CODING_AGENT_DIR. OMP_AGENT_DIR is this script's
# clearer override and takes precedence when both are set.
OMP_AGENT_DIR="${OMP_AGENT_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}}"
ORCA_EXTENSIONS=(orca-agent-status.ts orca-prefill.ts orca-titlebar-spinner.ts)
DEFAULT_PACKAGES=()

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
act() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'would: %s\n' "$*"
  else
    "$@"
  fi
}

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --mode symlink|copy   Install method (default: symlink)
  --profile NAME        full | minimal | orca (default: full)
  --with-orca           Include Orca extensions (default on for full/orca)
  --no-orca             Skip Orca extensions
  --skip-packages       Do not install plugins listed in agent/packages.list
  --omp-install         Install/update omp if missing
  --force               Replace managed targets even if they exist as regular files
  --dry-run             Preview actions without changing the system; prints a summary
  --doctor              Only verify the current install
  -h, --help            Show this help

Environment:
  OMP_AGENT_DIR         Override omp agent dir (default: ~/.omp/agent)
  PI_CODING_AGENT_DIR   Native omp-compatible agent-dir override
EOF
}

load_profile() {
  local file="$REPO_DIR/profiles/${PROFILE}.env"
  local cli_orca="$WITH_ORCA"
  if [[ -f "$file" ]]; then
    # shellcheck disable=SC1090
    source "$file"
    if [[ "$ORCA_SET" -eq 1 ]]; then
      WITH_ORCA="$cli_orca"
    fi
    if [[ "${INSTALL_PACKAGES:-1}" == "0" ]]; then
      SKIP_PACKAGES=1
    fi
    if [[ "${INSTALL_EXTENSIONS:-1}" == "0" ]]; then
      INSTALL_EXTENSIONS=0
    fi
  else
    warn "unknown profile '$PROFILE' (continuing with flags)"
  fi
}

timestamp() { date +%Y%m%d%H%M%S; }

backup_if_needed() {
  local target="$1"
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ -L "$target" ]]; then
      return 0
    fi
    local backup
    backup="${target}.bak.$(timestamp)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'would: mv %s %s\n' "$target" "$backup"
    else
      log "backup $target -> $backup"
      mv "$target" "$backup"
    fi
  fi
}

# Link or copy src -> dest. Existing live files are preserved as timestamped
# backups before symlink mode takes ownership of the path.
install_path() {
  local src="$1"
  local dest="$2"
  local dest_dir
  dest_dir="$(dirname "$dest")"

  [[ -e "$src" || -L "$src" ]] || die "missing source: $src"
  [[ -d "$dest_dir" ]] || act mkdir -p "$dest_dir"

  if [[ -L "$dest" ]]; then
    local current
    current="$(readlink "$dest")"
    if [[ "$current" == "$src" && "$FORCE" -eq 0 ]]; then
      log "ok symlink $dest"
      UNCHANGED=$((UNCHANGED + 1))
      return 0
    fi
    log "replace symlink $dest"
    act rm "$dest"
  elif [[ -e "$dest" ]]; then
    if [[ "$FORCE" -eq 0 && "$MODE" == "copy" && -f "$src" && -f "$dest" ]] && cmp -s "$src" "$dest"; then
      log "ok file $dest (identical)"
      UNCHANGED=$((UNCHANGED + 1))
      return 0
    fi
    backup_if_needed "$dest"
  fi

  if [[ "$MODE" == "symlink" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'would: ln -s %s %s\n' "$src" "$dest"
    else
      log "symlink $dest -> $src"
      ln -s "$src" "$dest"
    fi
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'would: cp -a %s %s\n' "$src" "$dest"
  else
    log "copy $src -> $dest"
    cp -a "$src" "$dest"
  fi
  CHANGES=$((CHANGES + 1))
}

ensure_omp() {
  if command -v omp >/dev/null 2>&1; then
    log "omp found: $(command -v omp)"
    return 0
  fi
  [[ "$INSTALL_OMP" -eq 1 ]] || die "omp not found on PATH. Install it, or re-run with --omp-install"

  if command -v bun >/dev/null 2>&1; then
    log "installing omp via bun"
    act bun install -g @oh-my-pi/pi-coding-agent
  elif command -v curl >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'would: curl -fsSL https://omp.sh/install | sh\n'
    else
      log "installing omp via https://omp.sh/install"
      curl -fsSL https://omp.sh/install | sh
    fi
  else
    die "--omp-install needs bun or curl"
  fi

  command -v omp >/dev/null 2>&1 || die "omp installed but not on PATH"
}

read_packages() {
  local manifest="$REPO_DIR/agent/packages.list"
  if [[ -f "$manifest" ]]; then
    local pkg
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
      pkg="${pkg#"${pkg%%[![:space:]]*}"}"
      pkg="${pkg%"${pkg##*[![:space:]]}"}"
      [[ -z "$pkg" || "$pkg" == \#* ]] && continue
      printf '%s\n' "$pkg"
    done < "$manifest"
    return
  fi
  printf '%s\n' "${DEFAULT_PACKAGES[@]}"
}

install_packages() {
  [[ "$SKIP_PACKAGES" -eq 1 ]] && { log "skip packages"; return 0; }
  ensure_omp

  local pkg
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'would: omp install %s\n' "$pkg"
      PKGS=$((PKGS + 1))
    else
      log "omp install $pkg"
      if ! omp install "$pkg"; then
        warn "omp install failed for $pkg (continuing)"
      fi
    fi
  done < <(read_packages)
}

is_orca_extension() {
  local name="$1"
  local extension
  for extension in "${ORCA_EXTENSIONS[@]}"; do
    [[ "$name" == "$extension" ]] && return 0
  done
  return 1
}

install_agent_files() {
  [[ -d "$OMP_AGENT_DIR/extensions" ]] || act mkdir -p "$OMP_AGENT_DIR/extensions"

  local file
  for file in config.yml models.yml; do
    [[ -f "$REPO_DIR/agent/$file" ]] || continue
    install_path "$REPO_DIR/agent/$file" "$OMP_AGENT_DIR/$file"
  done

  if [[ "$INSTALL_EXTENSIONS" -eq 0 ]]; then
    log "skip extensions (profile)"
  else
    local extension base
    shopt -s nullglob
    for extension in "$REPO_DIR/agent/extensions"/*; do
      [[ -f "$extension" ]] || continue
      base="$(basename "$extension")"
      if [[ "$WITH_ORCA" -eq 0 ]] && is_orca_extension "$base"; then
        log "skip orca extension $base"
        continue
      fi
      install_path "$extension" "$OMP_AGENT_DIR/extensions/$base"
    done
    shopt -u nullglob
  fi

  if [[ -d "$REPO_DIR/agent/agents" ]]; then
    local agent name
    shopt -s nullglob
    for agent in "$REPO_DIR/agent/agents"/*; do
      [[ -d "$agent" ]] || continue
      name="$(basename "$agent")"
      install_path "$agent" "$OMP_AGENT_DIR/agents/$name"
    done
    shopt -u nullglob
  fi
}

print_auth_help() {
  cat <<EOF

Auth (local only — never committed):
  Config dir: $OMP_AGENT_DIR/auth.json
  Example:    $REPO_DIR/auth/auth.json.example

In omp, use /login for OAuth providers (for example OpenAI Codex), or copy
that example to the config dir and fill API keys for configured providers.
EOF
}

ensure_auth() {
  local auth="$OMP_AGENT_DIR/auth.json"
  [[ -f "$auth" ]] && return 0

  local pi_auth="$HOME/.pi/agent/auth.json"
  if [[ -f "$pi_auth" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'would: cp -a %s %s\n' "$pi_auth" "$auth"
    else
      log "migrate pi auth $pi_auth -> $auth"
      mkdir -p "$(dirname "$auth")"
      cp -a "$pi_auth" "$auth"
    fi
    CHANGES=$((CHANGES + 1))
  fi
}

doctor() {
  local ok=1
  log "doctor: OMP_AGENT_DIR=$OMP_AGENT_DIR"
  log "doctor: REPO_DIR=$REPO_DIR"

  check_link() {
    local dest="$1"
    local src="$2"
    if [[ -L "$dest" ]]; then
      local current
      current="$(readlink "$dest")"
      if [[ "$current" == "$src" ]]; then
        printf '  OK  symlink %s\n' "$dest"
      else
        printf '  BAD symlink %s -> %s (expected %s)\n' "$dest" "$current" "$src"
        ok=0
      fi
    elif [[ -e "$dest" ]]; then
      if [[ "$MODE" == "copy" && -f "$dest" && -f "$src" ]] && cmp -s "$dest" "$src"; then
        printf '  OK  file %s (matches repo)\n' "$dest"
      else
        printf '  WARN present %s (not symlink to repo)\n' "$dest"
      fi
    else
      printf '  MISSING %s\n' "$dest"
      ok=0
    fi
  }

  check_link "$OMP_AGENT_DIR/config.yml" "$REPO_DIR/agent/config.yml"
  check_link "$OMP_AGENT_DIR/models.yml" "$REPO_DIR/agent/models.yml"

  if [[ "$INSTALL_EXTENSIONS" -eq 0 ]]; then
    printf '  OK  extensions skipped (profile)\n'
  else
    local extension base
    shopt -s nullglob
    for extension in "$REPO_DIR/agent/extensions"/*; do
      [[ -f "$extension" ]] || continue
      base="$(basename "$extension")"
      if [[ "$WITH_ORCA" -eq 0 ]] && is_orca_extension "$base"; then
        continue
      fi
      check_link "$OMP_AGENT_DIR/extensions/$base" "$extension"
    done
    shopt -u nullglob
  fi

  if [[ -f "$OMP_AGENT_DIR/auth.json" ]]; then
    printf '  OK  auth.json present (local)\n'
  else
    printf '  WARN auth.json missing — run /login or copy auth/auth.json.example\n'
  fi

  if command -v omp >/dev/null 2>&1; then
    printf '  OK  omp on PATH\n'
    if PI_CODING_AGENT_DIR="$OMP_AGENT_DIR" omp config list >/dev/null; then
      printf '  OK  config.yml parses\n'
    else
      printf '  BAD config.yml failed omp validation\n'
      ok=0
    fi
  else
    printf '  WARN omp not on PATH (install with ./install.sh --omp-install)\n'
  fi

  [[ "$ok" -eq 1 ]] || return 1
  log "doctor: all good"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --with-orca) WITH_ORCA=1; ORCA_SET=1; shift ;;
    --no-orca) WITH_ORCA=0; ORCA_SET=1; shift ;;
    --skip-packages) SKIP_PACKAGES=1; shift ;;
    --omp-install) INSTALL_OMP=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --doctor) DOCTOR_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$MODE" == "symlink" || "$MODE" == "copy" ]] || die "--mode must be symlink or copy"
load_profile

print_summary() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run summary: %d would change, %d up to date, %d plugin(s) to install\n' \
      "$CHANGES" "$UNCHANGED" "$PKGS"
  fi
}

if [[ "$DOCTOR_ONLY" -eq 1 ]]; then
  if doctor; then
    rc=0
  else
    rc=1
  fi
  [[ "$DRY_RUN" -eq 1 ]] && print_summary
  exit "$rc"
fi

log "repo:      $REPO_DIR"
log "omp agent: $OMP_AGENT_DIR"
log "mode:      $MODE"
log "profile:   $PROFILE"
log "orca:      $WITH_ORCA"

install_agent_files
install_packages
ensure_auth
print_auth_help

if [[ "$DRY_RUN" -eq 0 ]]; then
  doctor || warn "doctor reported issues"
else
  print_summary
fi

log "done"
