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
harnesses update          # Run each AI harness's own self-updater (claude, codex, opencode, ...)
harnesses schedule        # Install the daily 07:00 timer that runs 'harnesses update'
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

A module declares a dependency when the two are always installed together — not only when it would crash without it. `opencodex` keeps running if `providers` is missing, but it loses model filtering for every provider bar one, which is never a state worth shipping, so the edge is declared.

The current edges:

| Module | Requires | Why |
|--------|----------|-----|
| `providers` | `auth` | `auth` is the only door to the passage vault, and the vault is where 10 of 12 providers' credentials live |
| `opencodex` | `providers` | Without it, 11 of 12 registry providers lose model filtering |
| `kernel-simmer` | `schedule` | Renders its timer through the shared helper |
| `backup` | `schedule` | Same |
| `system-updates` | `schedule` | Same |
| `setup` | `fzf-multicolumn` | The interactive module picker has no stock-`fzf` fallback by design |
| `ai-menu` | `fzf-multicolumn` | The `ai` menu falls back to plain `fzf`, but loses its folder column and re-installs the picker on every run |
| `tmux` | `zsh-basics` | The status bar reads `SYSTEM_COLOR_HEX`, which only `zsh-basics` exports; without it every machine's bar is the same blue |

`setup` bootstraps `fzf-multicolumn` straight from the manifest on first interactive run, so a fresh `curl | zsh` install still lands a working picker — the declared edge only makes that hand-wired behavior explicit and blocks an uninstall that would immediately be undone.

Deliberately not declared, both on `harnesses`, for the same reason — the module is two jobs in one binary, and its updater half stands alone:

- `opencodex`: `harnesses install` and `harnesses update` work fine on a machine with no proxy, even though `harnesses proxy` refuses to run there.
- `auth`: same two commands need no credentials at all. `harnesses settings` skips only the MCP permission grants without it and reports the gap, and `harnesses mcp` refuses outright. Note that `harnesses daily` runs settings → mcp → update, so on a machine with no Common Auth login the daily timer reports a failure every run.

The one thing the column cannot express is a platform-conditional need: `providers` and `harnesses` need `schedule` on Linux but use launchd on macOS, so they keep their own runtime check instead.

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
| `schedule` | `~/.local/bin/schedule` | Shared systemd timer helper (unit rendering, enable/disable, status) plus an fzf registry of every timer on the machine; `setup`, `providers`, `backup`, `system-updates`, and `kernel-simmer` all render their timers through it |
| `backup` | `~/.local/bin/backup` | Restic-based incremental backup script to `bingus` |
| `system-updates` | `~/.local/bin/system-updates` | Safe daily package updater (Linux only, runs between 03:00–03:30). At 07:00, when a reboot is required, a model with a shell inspects what the machine is actually doing and decides whether rebooting is safe; anything short of a clear yes holds, and every decision goes to Telegram. `system-updates advise` asks without rebooting |

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
| `mac-boot` | Fleet-only macOS boot-volume switcher whose status shows the selected volume and other bootable choices; accepts exact volume names, switches through a narrowly scoped passwordless sudo rule, requests a normal application-aware restart, and guarantees reboot after 60 seconds | `files/mac-boot.sh` |
| `ai-menu` | Terminal AI launcher menu (`ai` command and interactive menu), with `ai --help` plus auto-launch enable/disable controls | `files/ai-menu.sh` |
| `claudex` | Claude Code multi-profile launcher (`~/.local/bin/claudex`) | `files/claudex.sh` |
| `opencodex` | Provider and harness launcher for OpenCodex (`~/.local/bin/opencodex`) | `files/opencodex.sh` |
| `auth` | Public Common Auth client: one browser-approved login, a local `0600` global/per-service credential store, and service-token resolution for other modules (`~/.local/bin/auth`) | `files/auth.sh` |
| `harnesses` | AI harness install/update, settings, and MCP enrollment for claude, codex, and hermes (where `~/.hermes/config.yaml` exists). The lost.plus MCP set is read from the Common Auth hub (`GET /api/services`: every registry row the account is admitted to that has an `mcp_url`, its `token_key` as the scope) with the global machine token `auth` holds, so a service registered in the hub enrolls everywhere on the next pass and the manifest lists only third-party MCPs; if the hub cannot be read the MCP pass fails loudly and changes nothing. lost.plus credentials come from `auth`, external-service credentials remain in the passage MCP (`~/.local/bin/harnesses`) | `files/harnesses.sh` |
| `providers` | Provider enrollment, credential mirrors, and model refresh; Grimoire uses `auth`, while third-party provider keys remain in the passage MCP (`~/.local/bin/providers`). OpenCode Zen is enrolled with its free-tier-only model policy and shares the existing OpenCode Go key (`~/.local/bin/providers`) | `files/providers.sh` |
| `tmux` | `tmux` setup with truecolor support, custom status bar, click-to-select, mouse scrolling, title hooks, and the `ssh` reconnect wrapper | `files/tmux.sh` |

Every module that installs a user-facing command supports `--help`. Configuration-only modules do not install a command.

`auth login` performs one browser-approved onboarding for the machine and stores a renewable setup session plus the account's active global or per-service bearer set locally with mode `0600`. It reports the machine hostname during login and later refreshes so Auth can identify each setup device without exposing its network address in the console. `auth status`, `auth refresh`, and `auth token` sync through `/api/setup/session/token`, so bearer rotations, revocations, token-mode changes, and admission changes arrive without another browser login. The local bundle and setup-managed consumer copies are bound to the Auth origin and immutable account subject. A confirmed session rejection is remembered and fails closed; temporary Auth unavailability may use the last-known-good bearer while that session remains active. Setup sessions and bearer tokens are separately revokable in Auth. `auth token` uses distinct exit statuses for authoritative absence, rejected setup sessions, and temporary failures, allowing `providers` and `harnesses` to remove only confirmed revoked managed mirrors while preserving same-account copies during outages or temporary unreadability. During MCP reconciliation, each declared credential source is authoritative; an existing environment or `.zshenv` value is used only as a last-known-good fallback when its source is unavailable. The module is available outside the trusted fleet boundary; Auth account admission still determines which service credentials a user can receive.

---

## Detailed Feature Overview

### AI Tools Integration

- **`agents`**: Deploys standard AI instructions (`AGENTS.md`) and skills to `~/.agents/`, and symlinks them into Claude Code (`~/.claude/`), Codex (`~/.codex/`), Antigravity (`~/.gemini/`), OpenCode (`~/.config/opencode/`), Muse Code (`~/.config/muse/`), and the home directory.
- **`resume`**: Scans active and previous sessions across Claude Code, Codex, OpenCode, Antigravity CLI, ForgeCode, Hermes, Grok, Kimi Code, and Muse Code so you can jump right back into any session.
- **`claudex` & `opencodex`**: Profile launchers that manage custom API keys, OAuth sessions, model aliases, and provider endpoints across multiple AI tools.
- **OpenCode Zen**: `providers` and `opencodex` use the existing `opencode-go` passage credential for Zen's OpenAI-compatible endpoint. Only known free or time-limited free model IDs, plus newly published IDs ending in `-free` or `alpha`, are admitted into the mirrored catalogs.
- **OpenCode Zen reasoning metadata**: Zen model IDs ending in `alpha` do not receive OpenCodex's generic reasoning ladder. If Zen later advertises model-specific effort levels, the refreshed capability cache takes precedence.
- **OpenCode Go/Zen session affinity**: `opencodex` carries the stable request/conversation lane required by OpenCode's free routes as `x-opencode-session` on both destinations. The setup module applies a version-checked compatibility patch to the installed OpenCodex runtime because the upstream transport currently gates this behavior to Go alone.
- **Harness updates**: `setup update` also self-updates every installed AI harness — Claude Code, Codex, OpenCode, Antigravity, Hermes, Grok, Kimi, Muse, and T3 Code. Each harness is a self-installing tool rather than a setup module, so setup locates it and runs its own updater (`claude update`, `opencode upgrade`, `hermes update --yes`, and so on). Muse has no update subcommand, so setup forces its launcher to refresh synchronously with `MUSE_SYNC_UPDATE=1 muse --version`. T3 Code is updated with `npx --yes t3@latest service update` only when its Linux background service is already installed; a real update briefly restarts that service. Harnesses missing from the machine are skipped. The module owns its own cadence: `harnesses schedule` installs a daily 07:00 timer (an hour clear of the 06:00 `setup schedule` timer) that runs `harnesses update`, and `setup enable harnesses` / `setup disable harnesses` drive that timer. `setup update` only updates modules, so `setup update harnesses` updates the harnesses module itself like any other filter. Unattended runs defer any module update that needs an interactive administrator prompt and report the command to run later in a terminal.

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

Every `SKILL.md` under `agents/skills/` carries an `audience:` line in its front matter. `audience: fleet` installs the skill only on machines whose key appears in the owner key list; `audience: public` installs it everywhere. The `agents` module reads this line when it links skills into each harness's skills directory, so a skill that skips the tag reads as unset rather than intentionally scoped. The pre-commit hook blocks a commit when any `SKILL.md` is missing it.
