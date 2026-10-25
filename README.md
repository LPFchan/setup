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

On Windows there is no `setup`; this PowerShell command enrolls the machine in the fleet (see [fleet on Windows](#fleet-on-windows)):

```powershell
irm https://raw.githubusercontent.com/LPFchan/setup/main/install.ps1 | iex
```

Running `setup` without arguments opens an interactive terminal menu (powered by `fzf`) where you can pick, install, update, or configure modules.

---

## Commands

```bash
setup                     # Open interactive menu to pick and configure modules
setup list                # List all available modules
setup status              # Check installed versions and remote updates
setup update              # Update all installed modules
fleet install [name...]   # Install harnesses with their own installers; asks which when none named
fleet update              # Run each AI harness's own self-updater (claude, codex, opencode, ...)
fleet sync                # Sync ~/.agents with the account and render harness settings
fleet schedule            # Install the nightly 04:00 timer that runs 'fleet nightly'
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

A module declares a dependency when the two are always installed together — not only when it would crash without it. `opencodex` depends on `fleet`, which supplies account provider settings, credential mirrors and model capabilities.

The current edges:

| Module | Requires | Why |
|--------|----------|-----|
| `fleet` | `auth` | Account sync and Passage credentials use the machine's Common Auth login |
| `opencodex` | `fleet` | Fleet supplies provider connections and the shared model capability cache |
| `kernel-simmer` | `schedule` | Renders its timer through the shared helper |
| `backup` | `schedule` | Same |
| `system-updates` | `schedule`, `fleet` | `schedule` for the timer; `fleet` because `fleet install miniharness` provides the model summon its 07:00 reboot check asks, and `system-updates enable` refuses to run without it |
| `setup` | `fzf-multicolumn` | The interactive module picker has no stock-`fzf` fallback by design |
| `ai-menu` | `fzf-multicolumn` | The `ai` menu falls back to plain `fzf`, but loses its folder column and re-installs the picker on every run |
| `tmux` | `zsh-basics` | The status bar reads `SYSTEM_COLOR_HEX`, which only `zsh-basics` exports; without it every machine's bar is the same blue |

`setup` bootstraps `fzf-multicolumn` straight from the manifest on first interactive run, so a fresh `curl | zsh` install still lands a working picker — the declared edge only makes that hand-wired behavior explicit and blocks an uninstall that would immediately be undone.

The column cannot express a platform-conditional dependency: fleet uses `schedule` on Linux, launchd on macOS and Task Scheduler on Windows. `bin/setup` adds the Linux dependency.

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
| `schedule` | `~/.local/bin/schedule` | Shared systemd timer helper (unit rendering, enable/disable, status) plus an fzf registry of every timer on the machine; `setup`, `fleet`, `backup`, `system-updates`, and `kernel-simmer` all render their timers through it |
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
| `opencodex` | Provider and harness launcher for OpenCodex (`~/.local/bin/opencodex`) | `files/opencodex.sh` |
| `auth` | Public Common Auth client: one browser-approved login, a local `0600` global/per-service credential store, and service-token resolution for other modules (`~/.local/bin/auth`) | `files/auth.sh` |
| `fleet` | SSH aliases, the account's `~/.agents` tree (instructions, skills, settings, MCP list) synced through Common Auth, harness settings rendered from it, the skill marketplace, provider credentials and models, and harness install/update (`~/.local/bin/fleet`) | `files/fleet.sh` |
| `tmux` | `tmux` setup with truecolor support, custom status bar, click-to-select, mouse scrolling, title hooks, and the `ssh` reconnect wrapper | `files/tmux.sh` |

The `fleet` module also sets an outbound default of
`StrictHostKeyChecking accept-new`, including destinations outside the alias
list. OpenSSH automatically records first-seen keys in its normal known-hosts
files and rejects changed keys; first use is trust-on-first-use, not independent
verification of the server. Existing `known_hosts` files are never cleared or
rewritten by setup. This replaces the old `yeowoolmac` exception that disabled
checking and discarded keys, so changing that machine's boot partition may now
require investigating a host-key mismatch rather than silently accepting it.

The managed default follows existing configuration and uses `Match final` so
second-pass user policies are considered first. OpenSSH's first-value-wins rules preserve earlier explicit user policies (including stricter `yes` or
`ask`); an earlier `no` or custom `UserKnownHostsFile` can still override normal
protection. Command-line options also take precedence. Install/update replaces
only setup's managed blocks, status detects policy drift, and uninstall removes
the default without removing saved host keys. Machines receive this through
normal setup updates, including their enabled nightly schedule.

Every module that installs a user-facing command supports `--help`. Configuration-only modules do not install a command.

`auth login` performs one browser-approved onboarding for the machine and stores a renewable setup session plus the account's active global or per-service bearer set locally with mode `0600`. It reports the machine hostname during login and later refreshes so Auth can identify each setup device without exposing its network address in the console. `auth status`, `auth refresh`, and `auth token` sync through `/api/setup/session/token`, so bearer rotations, revocations, token-mode changes, and admission changes arrive without another browser login. The local bundle and setup-managed consumer copies are bound to the Auth origin and immutable account subject. A confirmed session rejection is remembered and fails closed; temporary Auth unavailability may use the last-known-good bearer while that session remains active. Setup sessions and bearer tokens are separately revokable in Auth. `auth token` uses distinct exit statuses for authoritative absence, rejected setup sessions, and temporary failures, allowing fleet to remove only confirmed revoked managed mirrors while preserving same-account copies during outages or temporary unreadability. During MCP reconciliation, each declared credential source is authoritative; an existing environment or `.zshenv` value is used only as a last-known-good fallback when its source is unavailable. The module is available outside the trusted fleet boundary; Auth account admission still determines which service credentials a user can receive.

---

### fleet

`fleet sync` keeps `~/.agents` in step with the account's copy in Common Auth. Each file is compared three ways (server, last synced, local): one-sided changes move in that direction, and a file changed on both sides takes the server copy and backs the local one up under `~/.local/state/fleet/backup/`. Skills installed from the marketplace (`fleet skills`) arrive the same way.

After syncing, fleet renders harness settings line by line: it only touches the keys it manages and records what it wrote in `~/.local/state/fleet/rendered.json`, so anything else in a harness's settings file is left alone. Personal settings come from `~/.agents/settings/*.json` and `~/.agents/mcp.json`; settings every account shares come from `files/fleet-manifest.json`. Claude's claude.ai connectors are off for every account by default (`disableClaudeAiConnectors`); an account turns them back on with `"disableClaudeAiConnectors": false` in `settings/claude.json`. The lost.plus MCP servers come from `GET /api/services`, which already filters out admin-only services for accounts that aren't admitted. MCP tokens are read from passage and written to a marked block in `~/.zshenv`; Claude reads them through `fleet mcp-headers`, so a Claude started by a service still gets them.

`fleet nightly` (04:00) runs the sync, then each harness's own updater.

Every account gets a built-in `fleet` skill, a manual for the agents on its machines. fleet writes `~/.agents/skills/fleet/SKILL.md` read-only on every sync and never pushes it, so it cannot be edited or deleted for good, and its text is the same on every account. `skills/fleet/references/` belongs to the account and syncs like any skill file: that is where an account keeps notes about its own machines, and the manual tells agents to read them.

#### Provider connections

The Auth dashboard's Providers tab shows the shared provider catalog. Administrators
manage provider URLs and model descriptors for every account. Each account keeps
its enabled choices in `~/.agents/settings/providers.json` (version 2, `enabled`
map), using the same three-way sync and stale-save protection as other fleet
files. API keys stay in the account's Passage `llm` folder as `*_API_KEY`.
Native Codex and Anthropic OAuth sessions stay on each machine.

The dashboard lists connections alphabetically and manages API-key enrollment
and enabled choices. Fleet caches the shared Auth catalog and projects its
definitions plus account choices into the local `~/.config/providers/registry.json`
used by OpenCode, Hermes, Pi and OpenCodex. Normal sync refreshes credentials and
settings. Model discovery runs in fleet's 04:00 nightly pass and preserves the
last good list during an outage. OpenCodex reads the resulting capability cache
directly. Neither sync nor model refresh restarts the proxy.

Run `python3 scripts/migrate-providers-to-fleet.py` once on each existing machine,
from this checkout after deploying Auth and before normal Fleet updates. It backs up
the old registry, state and executable under `~/.local/state/fleet/backup/providers-migration/`,
publishes proven account choices, installs this checkout's Fleet payload, and replaces
the old job after the new schedule succeeds. It preserves disabled schedules and can
be retried after failure. Normal Fleet sync and installation contain no migration steps.
Keys and cached models are bound to the Auth origin and account subject, and
confirmed key removal clears managed copies. New accounts start with optional
API-key providers disabled.

#### fleet on Windows

`install.ps1` sets the machine up natively, without WSL. It installs Python if there is none, puts `auth` and `fleet` in `~\.local\bin` with `.cmd` shims, signs in, syncs, and schedules `fleet nightly` in Task Scheduler at 04:00. One UAC prompt turns on the OpenSSH server: PowerShell 7 (or Windows PowerShell) as the login shell, the `Match Group administrators` block in `sshd_config` commented out so an admin's own `~\.ssh\authorized_keys` (which fleet writes) is the one sshd reads, password logins left on, and the firewall rule open on every network.

On Windows there is no keepout. Skills reach `~\.claude\skills` through directory junctions, which need neither Developer Mode nor elevation. `AGENTS.md` is copied to each harness rather than linked (a junction cannot point at a file, and file symlinks need Developer Mode); a copy whose content fleet did not write is moved aside as `.pre-agents.bak` first. MCP tokens go to `~\.local\state\fleet\mcp-tokens` instead of `.zshenv`. Harnesses install through the `windows` block of their manifest entry, run by Windows PowerShell; a harness without one (t3) is not offered. With no `setup` to update it, `fleet nightly` fetches the current `fleet`, `auth`, provider engine, provider defaults and manifest first. `tests/fleet-windows.py` runs on a Windows runner in CI.

fleet runs on the `python3` it finds, which on macOS can be the system's 3.9. Codex's `config.toml` is checked with `tomllib` (3.11+) or `tomli` when either is there; without one, fleet finds the operator's own servers by their `[mcp_servers.<name>]` headers.

## Detailed Feature Overview

### AI Tools Integration

- **`resume`**: Scans active and previous sessions across Claude Code, Codex, OpenCode, Antigravity CLI, ForgeCode, Hermes, Grok, Kimi Code, and Muse Code so you can jump right back into any session.
- **`opencodex`**: Profile launcher that manages custom API keys, OAuth sessions, model aliases, and provider endpoints across multiple AI tools.
- **Mixed-tier admission policy**: a provider descriptor may carry `model_allow_ids`, `model_allow_suffixes`, and `model_no_reasoning_suffixes`, which admit only known-free or newly published `-free`/`alpha` model IDs into the mirrored catalogs and keep `alpha` IDs off OpenCodex's generic reasoning ladder. OpenCode Zen used all three; it has since been retired, so no live provider sets them, and they remain for the next mixed free/paid endpoint.
- **Retiring a provider**: deleting a provider from the registry is not enough, because every consumer write path is an upsert — the credential and model list would sit on each machine forever. Name it in `retired_providers` and each refresh sweeps it out of the credential cache, the `.zshenv` key block, opencode's `auth.json` and provider block, the provider state, the capability cache, Hermes, and Pi. A name that is itself live, or that a live provider borrows as its credential, is rejected at validation.
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
