# setup

Curl-installable personal Linux/macOS machine setup.

This repo is the source of truth for live scripts and generated config.
Repo: https://github.com/LPFchan/setup

## Install

```bash
curl -fsSL https://setup.lost.plus/install.sh | bash
```

Installs `setup` CLI to `~/.local/bin/`, then runs `setup` (interactive fzf reconfigure) or batch-installs all modules.

## Modules

### File modules

| module | target | source |
|--------|--------|--------|
| `setup` | `~/.local/bin/setup` | `bin/setup` |
| `resume` | `~/.local/bin/resume` | `files/resume` |
| `kernel-simmer` | `~/.local/bin/kernel-simmer` | `bin/kernel-simmer` |
| `service-ctl` | `~/.local/bin/service-ctl` | `bin/service-ctl` |
| `gpu-fancontrol` | `~/.local/bin/gpu-fancontrol` | `files/gpu-fancontrol` |
| `monitoring` | `~/.local/bin/monitoring` | `files/monitoring` |
| `refresh-models` | `~/.local/bin/refresh-models` | `files/refresh-models` |
| `backup` | `~/.local/bin/backup` | `bin/backup` |

### Script modules

| module | installs | manages block | source |
|--------|----------|---------------|--------|
| `zsh-autocomplete` | `~/.zsh/zsh-autocomplete/` + `~/.zsh/zsh-defer/` | plugin source + history + autocomplete settings | `files/zsh-autocomplete.sh` |
| `zsh-syntax-highlighting` | `~/.zsh/zsh-syntax-highlighting/` | deferred syntax highlighting | `files/zsh-syntax-highlighting.sh` |
| `starship` | `~/.local/bin/starship` | cached starship init | `files/starship.sh` |
| `zsh-basics` | (none) | `setopt NO_NOMATCH`, `WORDCHARS` | `files/zsh-basics.sh` |
| `agents` | `~/.agents/` (AGENTS.md + FLEET.md + skills) | — | `files/agents.sh` |
| `ssh-aliases` | (none) | outbound `Host` aliases in `~/.ssh/config` | `files/ssh-aliases.sh` |
| `ai-menu` | `~/.bashrc.d/ai-menu` (fzf picker) | source + `ai` autolaunch in `~/.zshrc` | `files/ai-menu.sh` |
| `tmux` | `~/.local/bin/tmux-cpu-mem` (status helper) | mouse/status settings in `~/.tmux.conf` | `files/tmux.sh` |

Script modules differ from file modules: they define `install()`, `status()`, `update()`, `uninstall()` functions instead of copying a file. Git-cloned plugins are updated via `git pull`, binaries via re-running their installer.

### `agents` — canonical agent instructions

Installs the canonical agent payload from `agents/` (this repo) into `~/.agents/`
and symlinks it into every harness so all machines share one source of truth:

- `agents/AGENTS.md` → `~/.agents/AGENTS.md`, symlinked to `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/AGENTS.md`, `~/.config/opencode/AGENTS.md`
- `agents/FLEET.md` → `~/.agents/FLEET.md`, symlinked as `FLEET.md` beside each of the above
- `agents/skills/*` → `~/.agents/skills/`, symlinked per-skill into `~/.claude/skills/` and `~/.codex/skills/`

Existing real files/dirs at any target are backed up to `*.pre-agents.bak` before
symlinking; `uninstall` removes the symlinks and restores the backups. The module
keeps its own clone of this repo at `~/.local/state/setup/agents-src` and tracks
its git ref for update detection. Global skills carry a `version:` in frontmatter.

Edit the payload under `agents/` here, push, and `setup update` syncs every machine.

### `ssh-aliases` — outbound SSH host aliases

Manages a marker-delimited block of `Host` stanzas in `~/.ssh/config`, built from
the fleet table in `files/ssh-aliases.sh` and **omitting the current machine**
(matched by `hostname`; override with `SSH_ALIASES_SELF`). Also normalizes
`~/.ssh` (700) and `~/.ssh/config` (600) permissions. Keep the table in sync with
`agents/FLEET.md`.

## Commands

```bash
setup list                # list available modules
setup status              # show installed state (local/remote hashes)
setup install resume      # install + enable module
setup uninstall resume    # disable + remove module
setup enable kernel-simmer # enable service module
setup disable backup      # disable service module
setup update              # update installed modules, report new ones
setup diff resume         # show diff against remote
setup doctor              # check required tools (including git)
setup                     # interactive fzf reconfigure
```

## .zshrc managed blocks

Setup manages shell config via marker-delimited blocks in `.zshrc`:

```
# >>> setup:tmux-autostart >>>  — replace outbound SSH shell with `tmux new-session -A -s main`
# >>> setup:zsh-ai >>>          — interactive/tty/terminal guards + /exit alias (no longer autolaunches ai)
# >>> setup:ai-menu >>>         — source ~/.bashrc.d/ai-menu + `ai` autolaunch (owned by the ai-menu module)
# >>> setup:zsh-basics >>>      — NO_NOMATCH, WORDCHARS
# >>> setup:zsh-autocomplete >>> — plugin source + history settings + autocomplete config
# >>> setup:zsh-syntax-highlighting >>> — deferred syntax highlighting
# >>> setup:starship >>>        — cached starship init
```

`tmux-autostart` and `zsh-ai` are prepended (top of `.zshrc`, tmux-autostart
first so the SSH shell swaps into tmux before `ai` launches); the rest are
appended. The `ai-menu` block is appended by its module, so autolaunch runs at
the bottom of `.zshrc` once the shell is fully initialized.

Every managed block's first line is a warning so agents (and humans) know not to
edit inside it — the block is regenerated from source on `setup update`:

```
# [setup] managed block — do NOT edit between these markers; overwritten on 'setup update'. Source: LPFchan/setup
```

The warning is part of the block body, so it participates in drift detection.
Existing blocks are rewritten once (shown as `outdated`) on the next update.

Each block is guarded so missing plugins don't break the shell:
- `[[ -d "$HOME/.zsh/zsh-autocomplete" && -d "$HOME/.zsh/zsh-defer" ]]` for autocomplete
- `(( ${+functions[zsh-defer]} ))` for syntax-highlighting (checks if zsh-defer is loaded)
- `command -v starship` for starship

**Local-only content** (not managed by setup, stays in user space):
- Env vars, PATH additions, MCP tokens (should be in `.zshenv`)
- `_BREW_PREFIX="/opt/homebrew"` (Apple Silicon specific)
- fzf shell integration (intentionally disabled)
- `COMBINING_CHARS`, `disable log` (macOS `/etc/zshrc` replacements)

### Cleanup after first install

After `setup install` on a fresh machine, the `.zshrc` may have duplicate lines (old unmanaged content + new managed blocks). Use an LLM to identify and remove duplicates — the managed blocks are the source of truth.

## Shared helpers

`lib/script-helpers.sh` provides shared functions for script modules:

- `git_clone_if_missing` — idempotent git clone
- `git_local_ref` / `git_remote_ref` — local vs remote HEAD comparison
- `git_check_status` — returns 0=current, 1=outdated, 2=missing
- `git_pull_ff` — fast-forward only pull
- `setup_sha256_string` — hash a string (not a file)
- `record_script_state` / `script_state_for` — track state in `script-state.tsv`
- `is_script_installed` — check if a script module has been installed

Helpers are fetched from `SOURCE_URL/lib/script-helpers.sh` at startup and cached at `~/.local/state/setup/lib/`.

## State files

| File | Location | Purpose |
|------|----------|---------|
| `manifest.tsv` | repo | module declarations |
| `checksums.tsv` | repo | SHA256 of file module sources (auto-generated by pre-commit hook) |
| `installed.tsv` | `~/.local/state/setup/` | hash tracking for file modules |
| `script-state.tsv` | `~/.local/state/setup/` | hash/version tracking for script modules |

## Design

- GitHub is the canonical code host.
- GitHub Pages serves the public installer at `https://setup.lost.plus`.
- `install.sh` bootstraps the updater CLI.
- `manifest.tsv` declares module, target path, mode, and source path.
- `mode=script` modules are fetched from SOURCE_URL and executed locally.
- Each managed source file declares its own module and version.
- Secrets do not belong in this repo.

## Contributing

After cloning, enable the tracked pre-commit hook:

```bash
git config core.hooksPath hooks
```

The hook runs `bash -n` syntax checks and regenerates `checksums.tsv` on commit.
