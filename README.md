# setup

Personal Linux and macOS machine setup, installed with a single command.

This repository is the single source of truth for all live setup scripts and managed configurations.

**Repository:** https://github.com/LPFchan/setup

---

## Quick Start

Run this command in `zsh` to install:

```zsh
curl -fsSL https://setup.lost.plus/install.sh | zsh
```

> **Note:** `zsh` is required. The installer places the `setup` CLI tool in `~/.local/bin/`.

fleet does not need `setup`, and lives in [LPFchan/auth](https://github.com/LPFchan/auth) (see [fleet](#fleet)). To enroll a macOS or Linux machine in the fleet:

```sh
curl -fsSL https://auth.lost.plus/fleet.sh | sh
```

On Windows there is no `setup`; this PowerShell command enrolls the machine in the fleet:

```powershell
irm https://auth.lost.plus/fleet.ps1 | iex
```

Running `setup` without arguments opens an interactive terminal menu (powered by `fzf`) where you can pick, install, update, or configure modules.

---

## Commands

```bash
setup                     # Open interactive menu to pick and configure modules
setup list                # List all available modules
setup status              # Check installed versions and remote updates
setup update              # Update all installed modules
setup install <module>    # Install and enable a module (e.g., setup install resume)
setup uninstall <module>  # Disable and remove a module
setup enable <module>     # Enable a background service module (e.g., setup enable system-updates)
setup disable <module>    # Disable a background service module
setup diff <module>       # Show differences between local setup and remote repository
setup doctor              # Check for required tools (like git)
setup schedule            # Set up the daily 06:00 automatic update timer
setup schedule status     # Check if the auto-update timer is active
```

---

## How Modules Work

Setup automatically filters available modules based on your machine:

1. **Audience Filter:** Compares your public SSH key (`~/.ssh/*.pub`) against the team key list at `https://github.com/LPFchan.keys`. If your key matches, fleet-only modules are made available.
2. **Platform Filter:** Checks your operating system (`Linux` or `macOS`) and shows only modules that work on your system.
3. **Dependency Filter:** A module whose dependency the first two filters hid is hidden too, since installing it could never complete.

For each online run, setup resolves the repository's `main` branch to one exact commit before fetching module metadata and payloads. This keeps status checks and installs on the same repository snapshot even while GitHub's raw-file caches are refreshing.

### Dependencies

A module names what it needs in the manifest's `requires` column (comma-separated module names):

- Installing a module installs its dependencies first, and prints what it pulled in.
- Uninstalling is refused while another installed module still needs it — with a yes/no prompt when there is a terminal, and a hard refusal when there is not.
- A module installed only as a dependency is remembered, so removing the last thing that needed it offers to take it away too.
- A dependency cycle is a hard error naming the module it runs through.

A module declares a dependency when the two are always installed together — not only when it would crash without it. `opencodex` depends on `fleet`, which installs and runs the OpenCodex proxy the picker launches through.

The current edges:

| Module | Requires | Why |
|--------|----------|-----|
| `opencodex` | `fleet` | Fleet runs the ocx proxy and writes the provider registry and model capabilities the picker reads |
| `kernel-simmer` | `schedule` | Renders its timer through the shared helper |
| `backup` | `schedule` | Same |
| `system-updates` | `schedule`, `fleet` | `schedule` for the timer; `fleet` because `fleet install miniharness` provides the model summon its 07:00 reboot check asks, and `system-updates enable` refuses to run without it |
| `setup` | `fzf-multicolumn` | The interactive module picker has no stock-`fzf` fallback by design |
| `ai-menu` | `fzf-multicolumn` | The `ai` menu falls back to plain `fzf`, but loses its folder column and re-installs the picker on every run |
| `tmux` | `zsh-basics` | The status bar reads `SYSTEM_COLOR_HEX`, which only `zsh-basics` exports; without it every machine's bar is the same blue |

`setup` bootstraps `fzf-multicolumn` straight from the manifest on first interactive run, so a fresh `curl | zsh` install still lands a working picker — the declared edge only makes that hand-wired behavior explicit and blocks an uninstall that would immediately be undone.

#### External requirements

Some modules need tools that are not modules, so the `requires` column cannot reach them. These surface only when a module refuses to run:

| Module | Needs | Where it comes from |
|--------|-------|---------------------|
| `backup` | restic ≥ 0.17, `flock`, `ssh-keygen` | System packages |
| `system-updates` | `hermes` and `miniharness` on the operator's PATH | `fleet install hermes` and `fleet install miniharness` (miniharness needs node and npm) |

---

## Modules

### File Modules

Simple modules that copy a managed script or executable to your machine.

| Module | Target Path | Description |
|--------|-------------|-------------|
| `setup` | `~/.local/bin/setup` | Main setup CLI tool |
| `resume` | `~/.local/bin/resume` | Quick interactive session selector for AI coding tools (Claude, Codex, OpenCode, Antigravity, Grok, Kimi, Muse, etc.) |
| `kernel-simmer` | `~/.local/bin/kernel-simmer` | Fleet-only kernel performance tuning tool |
| `gpu-fancontrol` | `~/.local/bin/gpu-fancontrol` | GPU fan speed control script |
| `monitoring` | `~/.local/bin/monitoring` | System monitoring utility |
| `schedule` | `~/.local/bin/schedule` | Shared systemd timer helper (unit rendering, enable/disable, status) plus an fzf registry of every timer on the machine; `setup`, `backup`, `system-updates`, and `kernel-simmer` render their timers through it (fleet writes its own) |
| `backup` | `~/.local/bin/backup` | Restic-based incremental backup script to `bingus` |
| `system-updates` | `~/.local/bin/system-updates` | Safe daily package updater (Linux only, runs between 03:00–03:30). At 07:00, when a reboot is required, a model with a shell inspects what the machine is actually doing and decides whether rebooting is safe; anything short of a clear yes holds, and every decision goes to Telegram. `system-updates advise` asks without rebooting |

---

### Script Modules

Modules that run setup, update, and cleanup scripts to configure tools and shell environments.

| Module | What it installs / manages | Source File |
|--------|---------------------------|-------------|
| `zsh-omnibar` | [zsh-omnibar](https://github.com/LPFchan/zsh-omnibar) — one ranked list blending history and completions (`~/.zsh/`) | `files/zsh-omnibar.sh` |
| `zsh-syntax-highlighting` | Command syntax highlighting (`~/.zsh/`) | `files/zsh-syntax-highlighting.sh` |
| `starship` | Custom shell prompt (`~/.local/bin/starship`) | `files/starship.sh` |
| `fzf-multicolumn` | Multi-column `fzf` wrapper used by the module picker and `ai` menu (`~/.local/bin/fzf-multicolumn`) | `files/fzf-multicolumn.sh` |
| `zsh-basics` | Machine color identity, common aliases (`/exit`, `ll`), and basic zsh options | `files/zsh-basics.sh` |
| `mac-boot` | Fleet-only macOS boot-volume switcher whose status shows the selected volume and other bootable choices; accepts exact volume names, switches through a narrowly scoped passwordless sudo rule, requests a normal application-aware restart, and guarantees reboot after 60 seconds | `files/mac-boot.sh` |
| `ai-menu` | Terminal AI launcher menu (`ai` command and interactive menu), with `ai --help` plus auto-launch enable/disable controls | `files/ai-menu.sh` |
| `opencodex` | Provider, model, effort and harness picker that launches through fleet's OpenCodex proxy (`~/.local/bin/opencodex`) | `files/opencodex.sh` |
| `auth` | Retired: `auth` comes with fleet now (see [fleet](#fleet)) | `files/auth.sh` |
| `fleet` | Hands the machine to standalone fleet (see [fleet](#fleet)); kept so `setup install fleet` in an old onboarding prompt still works | `files/fleet.sh` |
| `tmux` | `tmux` setup with truecolor support, custom status bar, click-to-select, mouse scrolling, title hooks, and the `ssh` reconnect wrapper | `files/tmux.sh` |

Every module that installs a user-facing command supports `--help`. Configuration-only modules do not install a command.


---

### fleet

fleet and `auth` live in [LPFchan/auth](https://github.com/LPFchan/auth) under `fleet/`, and Auth serves them at `https://auth.lost.plus/fleet/<name>`; their docs are `fleet/README.md` there. setup keeps only the `fleet` module, which hands a machine over: on its next `setup update` it runs `https://auth.lost.plus/fleet.sh`, and once fleet's own timer is on, setup drops `fleet` and `auth` from its state without uninstalling them; any failure leaves everything as it was for the next run to retry. If nothing else on the machine came from setup (modules installed only as dependencies do not count), setup then removes its own timer, those dependencies, `~/.local/bin/setup` and its state; the `setup:path` block and the `setup:` markers around fleet's blocks stay. `tests/fleet-handover.sh` covers this against a stand-in fleet.

`files/fleet`, `files/auth`, `files/fleet-providers.py`, `files/fleet-manifest.json` and `files/provider-registry.json` are frozen copies of Auth's. A fleet installed before the move still updates itself from here once, and these copies point it at Auth; they go once every machine has made that step.

---

## Detailed Feature Overview

### AI Tools Integration

- **`resume`**: Scans active and previous sessions across Claude Code, Codex, OpenCode, Antigravity CLI, ForgeCode, Hermes, Grok, Kimi Code, and Muse Code so you can jump right back into any session.
- **`opencodex`**: A terminal picker of provider, model, effort and harness (Claude Code, Codex, Grok, Kimi Code) that launches through fleet's OpenCodex proxy. It reads fleet's provider registry and capability cache, `opencodex list` prints the same choices for scripts, and `opencodex run` launches one directly. When ocx or its proxy is missing it says what to run rather than fixing it.
- **Mixed-tier admission policy**: a provider descriptor may carry `model_allow_ids`, `model_allow_suffixes`, and `model_no_reasoning_suffixes`, which admit only known-free or newly published `-free`/`alpha` model IDs into the mirrored catalogs and keep `alpha` IDs off OpenCodex's generic reasoning ladder. OpenCode Zen used all three; it has since been retired, so no live provider sets them, and they remain for the next mixed free/paid endpoint.
- **Retiring a provider**: deleting a provider from the registry is not enough, because every consumer write path is an upsert — the credential and model list would sit on each machine forever. Name it in `retired_providers` and each refresh sweeps it out of the credential cache, the `.zshenv` key block, opencode's `auth.json` and provider block, the provider state, the capability cache, Hermes, Pi, and OpenCodex's config. A name that is itself live, or that a live provider borrows as its credential, is rejected at validation.
- **OpenCode Go session affinity**: `opencodex` carries the stable request/conversation lane required by OpenCode's routes as `x-opencode-session`. This is upstream behaviour — setup used to patch the installed runtime to extend it to OpenCode Zen as well, but Zen is retired and OpenCodex 2.59.0 rewrote that transport, so the patch is gone and the runtime is installed verbatim.

---

### Shell & Environment Configuration

Setup manages your `~/.zshrc` using guarded blocks. Block order is automatically maintained from top to bottom:

1. `tmux-autostart` — Automatically launches or attaches to a main tmux session on interactive terminals
2. `tmux-title` — Updates window titles with active commands and SSH destinations
3. `zsh-basics` — Sets default environment options, machine color scheme, and handy aliases
4. `ssh-reconnect` — Wraps `ssh` so a suspended laptop reattaches instead of leaving a dead terminal (owned by the `tmux` module)
5. `starship` — Initializes the Starship prompt
6. `zsh-omnibar` — Sets up the blended history/completion list
7. `zsh-syntax-highlighting` — Enables syntax highlighting
8. `ai-menu` — Enables the `ai` menu command and autolaunch hook

> ⚠️ **Warning:** Do not edit inside managed blocks marked `# >>> setup:<name> >>>`. Any changes inside these blocks will be overwritten when running `setup update`. Add custom shell configs outside these blocks or in `~/.zshenv`.

---

### Surviving a Laptop Suspend (`tmux` module)

Closing the lid strands the TCP session of every open SSH login. Two things then
go wrong: the client waits out the full TCP timeout before admitting the link is
dead, and the terminal is left in whatever modes the remote tmux had set — with
SGR mouse reporting still enabled, every mouse movement types an escape sequence
at the local prompt, so the window has to be thrown away.

This lives in the `tmux` module rather than `fleet`: this module is what
turns mouse mode on, so it owns undoing it, and the reattach is only lossless
because the same module installs `tmux-autostart` on every machine. The `Host`
stanza options below stay in `fleet`, which owns `~/.ssh/config`.

- The `ssh-reconnect` block wraps `ssh` in interactive shells. It restores the
  local terminal on every return, and reconnects on a dropped link — landing
  back in the shared `main` tmux session with scrollback and jobs intact.
- Resume is immediate rather than timeout-driven. Sleep freezes every process,
  so a jump in wall-clock time across a two-second tick is a free and reliable
  wake signal; a watcher hangs up the stale client the moment the lid opens
  instead of letting it wait out its keepalives. Nothing polls while asleep.
- Reconnects retry at a flat one-second cadence, not exponential backoff: the
  network is either back when the lid opens or it is not, and a growing delay
  only adds dead time to the common case. `ConnectTimeout 5` keeps an attempt
  made before Wi-Fi reassociates from stalling.
- Generated `Host` stanzas still carry `ServerAliveInterval 15` /
  `ServerAliveCountMax 3`, which covers drops with no sleep involved — walking
  out of Wi-Fi range — where there is no clock jump to detect.
- It engages only on a plain login: exactly one non-option operand, no remote
  command, and a TTY on both stdin and stdout. `ssh host cmd`, forwarding-only
  sessions, scripts, and agent invocations keep stock behavior. A session that
  never came up is never retried, so an unreachable host still fails at once.

### Unique Machine Color Scheme

The `zsh-basics` module automatically generates a unique, consistent color identity for your machine based on its hostname:
- `SYSTEM_COLOR_HUE`: Integer hue derived from `cksum(hostname)`
- `SYSTEM_COLOR_HEX`: Vibrant `#RRGGBB` hex color
- `SYSTEM_COLOR_TEXT_HEX`: High-contrast black or white text color

This color is exported to your environment and used by `tmux` and other tools for clear visual identification across servers.

---

### Backups (`backup` module)

- Uses [Restic](https://restic.net/) for daily incremental backups to `bingus` over SFTP (around 09:00 AM).
- Backs up user files up to 20 MiB, excluding temporary build and cache directories.
- Full backup path exceptions (like `~/Eastself`) are backed up without size limits.
- Automatically saves dependency environment manifests for Python, Node.js, and Rust projects.

---

## Shared Helpers & State Files

Configuration and state are tracked locally in `~/.local/state/setup/`:

| File | Location | Purpose |
|------|----------|---------|
| `manifest.tsv` | Repository | Catalog of available modules, target paths, and requirements |
| `checksums.tsv` | Repository | SHA256 checksums of source files |
| `installed.tsv` | `~/.local/state/setup/` | Tracks installed file modules |
| `script-state.tsv` | `~/.local/state/setup/` | Cache of script module installation states and versions |

---

## Contributing

To contribute or modify setup scripts, set up the pre-commit hook:

```bash
git config core.hooksPath hooks
```

The hook automatically runs `zsh -n` and `bash -n` syntax checks and updates `checksums.tsv` whenever you make a commit.
