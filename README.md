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

Running `setup` without arguments opens an interactive terminal menu (powered by `fzf`) where you can pick, install, update, or configure modules.

---

## Commands

```bash
setup                     # Open interactive menu to pick and configure modules
setup list                # List all available modules
setup status              # Check installed versions and remote updates
setup update              # Update all installed modules and AI harnesses
setup update harnesses    # Update only the AI harnesses (claude, codex, opencode, ...)
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

---

## Modules

### File Modules

Simple modules that copy a managed script or executable to your machine.

| Module | Target Path | Description |
|--------|-------------|-------------|
| `setup` | `~/.local/bin/setup` | Main setup CLI tool |
| `resume` | `~/.local/bin/resume` | Quick interactive session selector for AI coding tools (Claude, Codex, OpenCode, Antigravity, Grok, Kimi, Muse, etc.) |
| `kernel-simmer` | `~/.local/bin/kernel-simmer` | Fleet-only kernel performance tuning tool |
| `service-ctl` | `~/.local/bin/service-ctl` | Fleet-only system service controller |
| `gpu-fancontrol` | `~/.local/bin/gpu-fancontrol` | GPU fan speed control script |
| `monitoring` | `~/.local/bin/monitoring` | System monitoring utility |
| `backup` | `~/.local/bin/backup` | Restic-based incremental backup script to `bingus` |
| `system-updates` | `~/.local/bin/system-updates` | Safe daily package updater (Linux only, runs between 03:00–03:30) |

---

### Script Modules

Modules that run setup, update, and cleanup scripts to configure tools and shell environments.

| Module | What it installs / manages | Source File |
|--------|---------------------------|-------------|
| `zsh-autocomplete` | Tab completion and history configuration (`~/.zsh/`) | `files/zsh-autocomplete.sh` |
| `zsh-syntax-highlighting` | Command syntax highlighting (`~/.zsh/`) | `files/zsh-syntax-highlighting.sh` |
| `starship` | Custom shell prompt (`~/.local/bin/starship`) | `files/starship.sh` |
| `zsh-basics` | Machine color identity, common aliases (`/exit`, `ll`), and basic zsh options | `files/zsh-basics.sh` |
| `agents` | AI agent instructions and skills (`~/.agents/`, linked to all installed AI harnesses) | `files/agents.sh` |
| `ssh-aliases` | Manages outbound host shortcuts in `~/.ssh/config` and syncs the owner's GitHub keys into a preserved block in `~/.ssh/authorized_keys` | `files/ssh-aliases.sh` |
| `mac-boot` | Fleet-only macOS boot-volume switcher whose status shows the selected volume and other bootable choices; accepts exact volume names and switches through a narrowly scoped passwordless sudo rule | `files/mac-boot.sh` |
| `ai-menu` | Terminal AI launcher menu (`ai` command and interactive menu), with `ai --help` plus auto-launch enable/disable controls | `files/ai-menu.sh` |
| `claudex` | Claude Code multi-profile launcher (`~/.local/bin/claudex`) | `files/claudex.sh` |
| `opencodex` | Provider and harness launcher for OpenCodex (`~/.local/bin/opencodex`) | `files/opencodex.sh` |
| `providers` | Vault-owned provider API keys: enrollment, local cache, and mirrors into opencode `auth.json`, `.zshenv`, and Hermes `~/.hermes/config.yaml` (live model discovery where available; registry-owned model lists for compatible endpoints without `/models`) (`~/.local/bin/providers`) | `files/providers.sh` |
| `tmux` | `tmux` setup with truecolor support, custom status bar, click-to-select, mouse scrolling, title hooks, and the `ssh` reconnect wrapper | `files/tmux.sh` |

Every module that installs a user-facing command supports `--help`. Configuration-only modules do not install a command.

---

## Detailed Feature Overview

### AI Tools Integration

- **`agents`**: Deploys standard AI instructions (`AGENTS.md`) and skills to `~/.agents/`, and symlinks them into Claude Code (`~/.claude/`), Codex (`~/.codex/`), Antigravity (`~/.gemini/`), OpenCode (`~/.config/opencode/`), Muse Code (`~/.config/muse/`), and the home directory.
- **`resume`**: Scans active and previous sessions across Claude Code, Codex, OpenCode, Antigravity CLI, ForgeCode, Hermes, Grok, Kimi Code, and Muse Code so you can jump right back into any session.
- **`claudex` & `opencodex`**: Profile launchers that manage custom API keys, OAuth sessions, model aliases, and provider endpoints across multiple AI tools.
- **Harness updates**: `setup update` also self-updates every installed AI harness — Claude Code, Codex, OpenCode, Antigravity, Hermes, Grok, Kimi, Muse, and T3 Code. Each harness is a self-installing tool rather than a setup module, so setup locates it and runs its own updater (`claude update`, `opencode upgrade`, `hermes update --yes`, and so on). Muse has no update subcommand, so setup forces its launcher to refresh synchronously with `MUSE_SYNC_UPDATE=1 muse --version`. T3 Code is updated with `npx --yes t3@latest service update` only when its Linux background service is already installed; a real update briefly restarts that service. Harnesses missing from the machine are skipped, and the daily `setup schedule` timer runs the full update at 06:00. Unattended runs defer any module update that needs an interactive administrator prompt and report the command to run later in a terminal.

---

### Shell & Environment Configuration

Setup manages your `~/.zshrc` using guarded blocks. Block order is automatically maintained from top to bottom:

1. `tmux-autostart` — Automatically launches or attaches to a main tmux session on interactive terminals
2. `tmux-title` — Updates window titles with active commands and SSH destinations
3. `zsh-basics` — Sets default environment options, machine color scheme, and handy aliases
4. `ssh-reconnect` — Wraps `ssh` so a suspended laptop reattaches instead of leaving a dead terminal (owned by the `tmux` module)
5. `starship` — Initializes the Starship prompt
6. `zsh-autocomplete` — Sets up tab completion and history search
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

This lives in the `tmux` module rather than `ssh-aliases`: this module is what
turns mouse mode on, so it owns undoing it, and the reattach is only lossless
because the same module installs `tmux-autostart` on every machine. The `Host`
stanza options below stay in `ssh-aliases`, which owns `~/.ssh/config`.

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
