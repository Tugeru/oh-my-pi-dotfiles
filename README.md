# oh-my-pi-dotfiles

Portable [Oh My Pi](https://omp.sh) setup: config, models, local extensions, optional unpacked agents, and pinned plugins.

Daily sync is **git**, not manual copying. Managed files are **symlinked** from this repo into OMP's agent directory, so edits made through OMP (for example `omp config set`) already modify the repository.

## What this manages

| Path in repo | Installs to / does |
|---|---|
| `agent/config.yml` | `~/.omp/agent/config.yml` |
| `agent/models.yml` | `~/.omp/agent/models.yml` |
| `agent/extensions/*` | `~/.omp/agent/extensions/*` |
| `agent/agents/*` (optional) | `~/.omp/agent/agents/*` |
| `agent/packages.list` | Installs each line with `omp install <package>` |

OMP shares `~/.agents/skills` with Pi. Skills are deliberately **not** managed here: they remain owned by [my-pi-dotfiles](https://github.com/Tugeru/my-pi-dotfiles), which already symlinks them into that shared directory. Install that repo first on a new machine if you want the shared skills.

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

`agent/models.yml` defines the custom Kie provider models. Its API-key command is:

```yaml
apiKey: "!jq -r '.kie.key' $HOME/.omp/agent/auth.json"
```

The `!cmd` form is evaluated by OMP, so the file contains no credential. The default roles in `agent/config.yml` can also use OMP's bundled providers (for example `openai-codex` and `opencode-go`). Use `/login` for OAuth providers such as OpenAI Codex.

## Plugins and optional agents

There are no plugins installed initially. Add a pinned plugin to `agent/packages.list`:

```text
package-name@1.2.3
```

Then run `./install.sh`; it invokes `omp install package-name@1.2.3`. If you install a plugin interactively, run `./scripts/sync-from-live.sh` to rebuild the tracked manifest from `~/.omp/agent/package.json`.

OMP writes unpacked user agents to `~/.omp/agent/agents/` (`omp agents unpack`). Run `./scripts/sync-from-live.sh` to import them; subsequent installs link each agent directory from `agent/agents/`.

## Checks

GitHub Actions runs ShellCheck, static structure/YAML checks, gitleaks, and isolated copy/symlink installer smoke tests.

Run locally:

```bash
./scripts/ci-check.sh              # needs: pip install pyyaml
shellcheck install.sh scripts/*.sh # if ShellCheck is installed
./install.sh --dry-run --skip-packages
```
