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
| `zsh-basics` | (none) | interactive/terminal guards, `/exit`, `setopt NO_NOMATCH`, Emacs keybindings, `WORDCHARS` | `files/zsh-basics.sh` |
| `agents` | `~/.agents/` (AGENTS.md + FLEET.md + skills) | — | `files/agents.sh` |
| `ssh-aliases` | (none) | outbound `Host` aliases in `~/.ssh/config` | `files/ssh-aliases.sh` |
| `ai-menu` | `~/.bashrc.d/ai-menu` (fzf picker) | source + `ai` autolaunch in `~/.zshrc` | `files/ai-menu.sh` |
| `tmux` | `~/.local/bin/tmux-cpu-mem` (status helper) | truecolor/mouse/one-line wheel scrolling/status settings in `~/.tmux.conf`; interactive-shell autostart in `~/.zshrc` (reloads a running server on install) | `files/tmux.sh` |

Script modules differ from file modules: they define `install()`, `status()`, `update()`, `uninstall()` functions instead of copying a file. Git-cloned plugins are updated via `git pull`, binaries via re-running their installer.

The block-writing modules (`zsh-basics`, `ssh-aliases`, `tmux`, `ai-menu`) detect **source drift**: `status()` derives its `expected` hash from the module's own desired content in scope (`BLOCK_CONTENT`, plus the helper/payload for combined modules) via `setup_managed_block_body` in `lib/script-helpers.sh`, and compares it to the installed block — so editing a module's source shows `outdated` before `setup update` re-applies it, mirroring how file modules compare against `checksums.tsv`. For `tmux`, the `.tmux.conf` block, `~/.zshrc` autostart block, and derived helper (`~/.local/bin/tmux-cpu-mem`) are checked together. For `ai-menu` the payload's source of truth is `files/ai-menu` in the module's git clone (`~/.local/state/setup/ai-menu-src`, synced on install/update); when that clone is present its payload is hashed too, otherwise `status()` falls back to the installed payload (no spurious `outdated`, but payload drift is uncovered until the next update repopulates the clone).

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
setup schedule            # install the daily auto-update timer
setup schedule status     # show whether the timer is configured and active
setup                     # interactive fzf reconfigure
```

## .zshrc managed blocks

Setup manages shell config via marker-delimited blocks in `.zshrc`, kept in a
fixed **canonical order** (top → bottom):

```
# >>> setup:tmux-autostart >>>  — replace every interactive shell outside tmux with `tmux new-session -A -s main`
# >>> setup:zsh-basics >>>      — interactive/tty/terminal guards + /exit alias + baseline zsh behavior
# >>> setup:starship >>>        — cached starship init
# >>> setup:zsh-autocomplete >>> — plugin source + history settings + autocomplete config (loads zsh-defer)
# >>> setup:zsh-syntax-highlighting >>> — deferred syntax highlighting (needs zsh-defer → after zsh-autocomplete)
# >>> setup:ai-menu >>>         — source ~/.bashrc.d/ai-menu + `ai` autolaunch (owned by the ai-menu module)
```

`tmux-autostart` and `zsh-basics` are prepended by their respective modules; the
remaining blocks are appended by their own script modules. Because
`manage_block` only sets a block's position at creation, the accumulated order
is otherwise historical — so after every run
`normalize_block_order` (defined in `bin/setup`, mirrored in `install.sh`)
reorders the managed blocks to the canonical `ZSHRC_BLOCK_ORDER` above,
idempotently and without touching unmanaged content. `tmux-autostart` runs first
(every interactive shell outside tmux swaps into it before anything heavy),
`zsh-basics`' early `return` guards precede what they gate,
`zsh-syntax-highlighting` follows
`zsh-autocomplete` (which loads `zsh-defer`), and `ai-menu` autolaunches `ai`
last once the shell is fully initialized. Blocks with unknown labels are kept and
sorted after the known ones.

> Migration: the core-owned `zsh-init` block (formerly `zsh-ai`) is folded into
> the module-owned `zsh-basics` block on update, so no orphaned duplicate
> remains.

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
- `setup_managed_block_body` — reproduce the exact block-body bytes `manage_block` writes (warning line + content), so a module can hash its *desired* block from source for drift detection
- `record_script_state` / `script_state_for` — track state in `script-state.tsv` (non-empty entry also marks a script module "installed" for `setup update`)
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
