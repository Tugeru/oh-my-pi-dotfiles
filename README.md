# oh-my-pi-dotfiles

Portable [Oh My Pi](https://omp.sh) setup: config, models, local extensions, optional unpacked agents, and pinned plugins.

Daily sync is **git**, not manual copying. Managed files are **symlinked** from this repo into OMP's agent directory, so edits made through OMP (for example `omp config set`) already modify the repository.

## What this manages

| Path in repo | Installs to / does |
|---|---|
| `agent/config.yml` | `~/.omp/agent/config.yml` |
| `agent/models.yml` | `~/.omp/agent/models.yml` |
| `agent/extensions/*` | `~/.omp/agent/extensions/*` |
| `agent/agents/*` (optional; `*.md` + dirs) | `~/.omp/agent/agents/*` |
| `agent/skills/*` (omp-native; e.g. `impeccable`) | `~/.omp/agent/skills/*` |
| `agent/packages.list` | Installs each line with `omp install <package>` |

Shared skills: `~/.agents/skills` (Pi/OMP `agents` provider) remain owned by [my-pi-dotfiles](https://github.com/Tugeru/my-pi-dotfiles) and its symlinks. OMP-native skills live in `~/.omp/agent/skills` (native provider) and are managed here; install that repo first on a new machine if you want the shared skills as well.

## Never tracked

- `auth.json` / API keys / OAuth tokens
- `ssh.json` and `smithery.json`
- `sessions/`, `blobs/`, `terminal-sessions/`
- `*.db*` runtime databases
- plugin install trees (`package.json`, `bun.lock`, `node_modules/`)

## New machine

```bash
git clone https://github.com/Tugeru/oh-my-pi-dotfiles.git ~/oh-my-pi-dotfiles
cd ~/oh-my-pi-dotfiles
./install.sh --omp-install
```

If `omp` is already installed, run `./install.sh` instead.

Then authenticate once:

```bash
omp
# /login  → OAuth providers such as OpenAI Codex
# or copy auth/auth.json.example → ~/.omp/agent/auth.json and fill API keys
```

If `~/.omp/agent/auth.json` is absent but Pi's `~/.pi/agent/auth.json` exists, the installer copies it once. It never overwrites or removes either auth file.

### Options

```bash
./install.sh --mode symlink|copy
./install.sh --profile full|minimal|orca
./install.sh --no-orca
./install.sh --skip-packages
./install.sh --omp-install
./install.sh --force
./install.sh --dry-run
./install.sh --doctor
```

`--dry-run` prints every pending system change and a summary without writing. `OMP_AGENT_DIR` overrides the target directory for this script; `PI_CODING_AGENT_DIR` is OMP's compatible native override and is honored when `OMP_AGENT_DIR` is unset.

Profiles:

- `full` — config, models, all extensions, and plugins.
- `minimal` — config, models, and plugins; no extensions.
- `orca` — same as full; named for the Orca-integrated environment.

`--no-orca` keeps core extensions (currently `persistent-error-retry.ts`) but omits the three Orca bridge extensions.

## Day-to-day workflow

**This machine (symlinks):**

1. Change config/models/extensions in OMP or an editor.
2. The linked file is already changed in this repo.
3. Review, commit, and push:

```bash
cd ~/orca/projects/oh-my-pi-dotfiles
git status
git diff
git add -p
git commit -m "chore: update omp defaults"
git push
```

**Other machine:**

```bash
git pull
./install.sh
```

OMP 17.3.0 writes `config.yml` in place through its symlink, so `omp config set` updates the tracked file directly. If a future version or a manual action replaces a link with a regular file, import the drift and relink it:

```bash
./scripts/sync-from-live.sh
git diff
# commit the imported changes, then:
./install.sh --force
```

`sync-from-live.sh` only imports the allowlisted config, models, extensions, optional agents, and plugin manifest. It never imports credentials or runtime state.

## Models and auth

`agent/models.yml` defines the custom Kie and 9router provider models. The Kie
API-key command is:

```yaml
apiKey: "!jq -r '.kie.key' $HOME/.omp/agent/auth.json"
```

The static `9router/oc/deepseek-v4-flash-free`, `9router/oc/x-preview-f-free`, and `9router/implementer` models
read their key from the untracked `~/.pi/agent/9router-config.json` created by
`/9router-config`.

`oc/x-preview-f-free` is registered with a 1,000,000-token context window,
text/image input, text output, low/high/max effort levels, and native tool
support. `ocg/ox-alpha-free` is likewise registered with a 1,000,000-token
context window (the router reports 200K), text/image input, low/high/max
effort levels, and native tool support. OMP 17.4's model schema currently
accepts only `text` and `image` input capabilities; it cannot declare or
forward a `video` model modality, so video remains unavailable through OMP
even if 9router advertises it.

The Kie provider models: Claude Opus 5, 4.8, 4.7, and 4.6 (Anthropic body), GPT-5.5 and GPT-5.6 Sol/Terra/Luna,
Grok 4.5/4.6 (Responses API), and
Gemini 3.6/3.7 Flash in both OpenAI-body and native Google-body forms. The native
`-google` models (api `google-generative-ai`) need
`agent/extensions/kie-gemini-compat.ts`: Kie omits `finishReason` on streamed
candidates and routes by API model name, so the extension drops `[DONE]`, injects
a synthetic STOP, and rewrites the `-google` id to the API id. Keep the google-body
`thinking.efforts` at `[low, medium, high]` — Kie 500s on `MINIMAL`.

## Plugins and optional agents

Two tracked plugins, both pinned in `agent/packages.list`:

```bash
omp install pi-9router-ext@0.2.3
omp install omniroute-pi-extension@2.2.0
```

Plugin trees live outside this repo under `$XDG_DATA_HOME/omp/plugins/` when `XDG_DATA_HOME` is set, otherwise the legacy `~/.omp/plugins/` root; `$OMP_PLUGIN_ROOT` overrides both. They are never tracked. If you install or update a plugin interactively, run `./scripts/sync-from-live.sh`; it rebuilds `agent/packages.list` from that root's `package.json`.

### 9router extension

`pi-9router-ext` connects omp to a [9router](https://github.com/decolua/9router) OpenAI-compatible AI routing proxy. After discovery, its models appear under the dynamic `9router/` provider namespace; existing providers are unchanged.

Configure the connection with environment variables:

```bash
NINE_ROUTER_BASE_URL=http://localhost:20128 # default
NINE_ROUTER_API_KEY=nr-...                  # only when 9router requires one
NINE_ROUTER_ENABLE_REASONING=true            # opt in to thinking levels
```

Or use `/9router-config` in omp. The extension writes that interactive configuration, including any API key, to the hardcoded `~/.pi/agent/9router-config.json`; it is shared with Pi and is never tracked here. Environment variables take precedence.

Commands: `/9router-status`, `/9router-models`, `/9router-config`, `/9router-reasoning`, `/9router-reload`. Tools: `ninerouter_status`, `ninerouter_web_search`, `ninerouter_web_fetch`. Reasoning is disabled by default. A reachable 9router instance is required before `9router/` models appear; an unreachable instance is a supported, non-fatal startup state.

The router's `/v1/models` reports no limits for combo routes (for example the `implementer` combo), and may omit callable routes such as `oc/x-preview-f-free`. The static definitions under the `9router` provider in `agent/models.yml` are authoritative: the extension reads them for matching ids and registers static-only ids as well. This relies on a small patch to the pinned `pi-9router-ext@0.2.3`, kept in `agent/patches/` and applied by `scripts/apply-9router-ext-patch.sh`. `./install.sh` runs it after plugin install, and `./install.sh --doctor` reports whether it is in place.

### Muse Spark through 9router

`oc/muse-spark-1.2-contributor-free` is served by the OpenCode Free endpoint. Its
OpenAI-compatible stream can end with content, usage, and `[DONE]` but no
choice-level `finish_reason`. OMP 17.4 normally rejects that stream as
`incomplete-stream` before it can execute a tool call.

This repo applies a version-guarded OMP 17.4 patch from
`scripts/apply-omp-muse-patch.sh`. For this exact 9router model, the patched
parser infers `stop` or `toolUse` when the stream closes. The existing
`pi-9router-ext` patch also sets `supportsFinishReason: false` for the model,
which keeps the runtime metadata explicit. The fix is scoped to this model and
does not change termination handling for other providers or models.

The patch is a local stopgap until OMP ships the compatibility override in its
configuration schema or 9router normalizes the upstream stream. The installer
skips unknown OMP versions instead of patching them blindly. Run
`./install.sh --doctor` after an OMP upgrade and reapply the patch if needed.

Tool calls, `read`, `write`, and `edit` remain available. A malformed or empty
upstream response is still an error. Proxy-pool selection remains in 9router.

### OmniRoute extension

`omniroute-pi-extension` integrates [OmniRoute](https://github.com/diegosouzapw/OmniRoute), the local AI gateway: `/omni` status/toggle/providers/log-review, plus a status-bar readout of which model actually served each response.

Ports matter here: this machine runs **9router on 20128 and OmniRoute on 20129** (two different routers, same default port — OmniRoute shifted up). The extension's own default is 20128, so the patched copy resolves the base URL from the `omni` provider in `agent/models.yml` first (env `OMNIROUTE_URL` still wins, then `~/.pi/agent/models.json`). The patched file lives in `agent/patches/omniroute-pi-extension@2.2.0/` and is applied by the same `scripts/apply-9router-ext-patch.sh` (now multi-plugin).

The `omni` provider in `agent/models.yml` statically declares this OmniRoute's 38 combo routes (`auto/*`) with the limits OmniRoute reports (`contextWindow`/`maxTokens`). OmniRoute does not enforce auth on `/v1/*`, so the apiKey is an optional `!jq` read of Pi's `~/.pi/agent/models.json`. Combos are created/edited in the OmniRoute dashboard; to refresh the list in omp run:

```text
/omni sync
```

Unlike stock, the patched extension writes `providers.omni.models` back into the omp `models.yml` (YAML) instead of Pi's `models.json` — omp never reads that file. `ctx.modelRegistry.refresh()` reloads the picker immediately, no restart needed. Management endpoints (`/api/*`) require the OmniRoute admin password (`/omni setup-key`); the inferencing endpoints (`/v1/*`) do not.

OMP writes unpacked user agents to `~/.omp/agent/agents/` (`omp agents unpack`). Run `./scripts/sync-from-live.sh` to import them; subsequent installs link each agent directory from `agent/agents/`.

## Impeccable design skill

`agent/skills/impeccable/` is the compiled `.pi` provider build of [Impeccable](https://impeccable.style), a 23-command frontend design skill. The installer symlinks it to `~/.omp/agent/skills/impeccable/`, the native omp skills root, so `/impeccable <command> <target>` works in any omp session. It needs Node.js (>= 22) on PATH for its bundled scripts; `npx impeccable` (the detector CLI) is an optional complement and is fetched from npm on first use.

The `.pi` build is used because omp is the Pi harness lineage: it carries the `allowed-tools` frontmatter (`Bash(npx impeccable *)`, `Bash(node .pi/skills/impeccable/scripts/*)`) and Pi path tokens. omp reports the skill's base directory to the agent, which resolves the `.pi/skills/impeccable/scripts/*` tokens against it at runtime — verified working on OMP 17.4.

Per-project setup (not part of this repo):

```text
/impeccable init      # creates PRODUCT.md (strategy)
/impeccable document  # creates DESIGN.md + .impeccable/design.json
```

The automatic design hook (detector on every UI edit) is not available on omp — Impeccable only wires hooks for Claude, Copilot, Codex, Cursor, and Grok. The skill covers the hookless case by running the bundled detector explicitly (`node <skill-dir>/scripts/detect.mjs --json` on changed targets). Live Mode works out of the box: it starts its own localhost server, independent of omp's `browser.enabled` setting.

To update the pinned skill, re-download the universal bundle and replace the tracked tree (no installer change needed):

```bash
cd /tmp
curl -fsSL -o impeccable-bundle.zip https://impeccable.style/api/download/bundle/universal
rm -rf /tmp/impeccable-update && mkdir -p /tmp/impeccable-update
unzip -q impeccable-bundle.zip '.pi/skills/impeccable/*' -d /tmp/impeccable-update
rsync -a --delete /tmp/impeccable-update/.pi/skills/impeccable/ \
  ~/oh-my-pi-dotfiles/agent/skills/impeccable/
cd ~/oh-my-pi-dotfiles && git add -A agent/skills/impeccable && git commit -m "chore: bump impeccable skill"
```

Check the current pinned version in `agent/skills/impeccable/SKILL.md` frontmatter, or run `npx impeccable check` from any project to compare against the npm latest.

## Checks

GitHub Actions runs ShellCheck, static structure/YAML checks, gitleaks, and isolated copy/symlink installer smoke tests.

Run locally:

```bash
./scripts/ci-check.sh              # needs: pip install pyyaml
shellcheck install.sh scripts/*.sh # if ShellCheck is installed
./install.sh --dry-run --skip-packages
```
