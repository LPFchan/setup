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
harnesses install [name]  # Install missing harnesses with their own installers (default: claude, codex)
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
| `system-updates` | `schedule`, `miniharness` | `schedule` for the timer; `miniharness` because `system-updates enable` refuses to run without the model summon its 07:00 reboot check asks |
| `setup` | `fzf-multicolumn` | The interactive module picker has no stock-`fzf` fallback by design |
| `ai-menu` | `fzf-multicolumn` | The `ai` menu falls back to plain `fzf`, but loses its folder column and re-installs the picker on every run |
| `tmux` | `zsh-basics` | The status bar reads `SYSTEM_COLOR_HEX`, which only `zsh-basics` exports; without it every machine's bar is the same blue |

`setup` bootstraps `fzf-multicolumn` straight from the manifest on first interactive run, so a fresh `curl | zsh` install still lands a working picker — the declared edge only makes that hand-wired behavior explicit and blocks an uninstall that would immediately be undone.

Deliberately not declared, both on `harnesses`, for the same reason — the module is two jobs in one binary, and its updater half stands alone:

- `opencodex`: `harnesses install` and `harnesses update` work fine on a machine with no proxy, even though `harnesses proxy` refuses to run there.
- `auth`: same two commands need no credentials at all. `harnesses settings` skips only the MCP permission grants without it and reports the gap, and `harnesses mcp` refuses outright. Note that `harnesses daily` runs settings → mcp → update, so on a machine with no Common Auth login the daily timer reports a failure every run.

The one thing the column cannot express is a platform-conditional need: `providers` and `harnesses` need `schedule` on Linux but use launchd on macOS, so they keep their own runtime check instead.

#### External requirements

Some modules need tools that are not modules, so the `requires` column cannot reach them. These surface only when a module refuses to run:

| Module | Needs | Where it comes from |
|--------|-------|---------------------|
| `backup` | restic ≥ 0.17, `flock`, `ssh-keygen` | System packages |
| `system-updates` | `hermes` on the operator's PATH | `harnesses install hermes` (Hermes's own installer, run non-interactively); not part of a bare `harnesses install` |
| `miniharness` | node and npm | nvm or `/opt/node`; the module reports what to do rather than installing node itself |

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
| `zsh-omnibar` | [zsh-omnibar](https://github.com/LPFchan/zsh-omnibar) — one ranked list blending history and completions (`~/.zsh/`) | `files/zsh-omnibar.sh` |
| `zsh-syntax-highlighting` | Command syntax highlighting (`~/.zsh/`) | `files/zsh-syntax-highlighting.sh` |
| `starship` | Custom shell prompt (`~/.local/bin/starship`) | `files/starship.sh` |
| `fzf-multicolumn` | Multi-column `fzf` wrapper used by the module picker and `ai` menu (`~/.local/bin/fzf-multicolumn`) | `files/fzf-multicolumn.sh` |
| `zsh-basics` | Machine color identity, common aliases (`/exit`, `ll`), and basic zsh options | `files/zsh-basics.sh` |
| `agents` | AI agent instructions and skills (`~/.agents/`, linked to all installed AI harnesses) | `files/agents.sh` |
| `ssh-aliases` | Manages outbound host shortcuts in `~/.ssh/config` and syncs the owner's GitHub keys into a preserved block in `~/.ssh/authorized_keys` | `files/ssh-aliases.sh` |
| `mac-boot` | Fleet-only macOS boot-volume switcher whose status shows the selected volume and other bootable choices; accepts exact volume names, switches through a narrowly scoped passwordless sudo rule, requests a normal application-aware restart, and guarantees reboot after 60 seconds | `files/mac-boot.sh` |
| `ai-menu` | Terminal AI launcher menu (`ai` command and interactive menu), with `ai --help` plus auto-launch enable/disable controls | `files/ai-menu.sh` |
| `opencodex` | Provider and harness launcher for OpenCodex (`~/.local/bin/opencodex`) | `files/opencodex.sh` |
| `auth` | Public Common Auth client: one browser-approved login, a local `0600` global/per-service credential store, and service-token resolution for other modules (`~/.local/bin/auth`) | `files/auth.sh` |
| `harnesses` | AI harness install/update, settings, and MCP enrollment for claude, codex, and hermes (where `~/.hermes/config.yaml` exists). The lost.plus MCP set is read from the Common Auth hub (`GET /api/services`: every registry row the account is admitted to that has an `mcp_url`, its `token_key` as the scope) with the global machine token `auth` holds, so a service registered in the hub enrolls everywhere on the next pass and the manifest lists only third-party MCPs; if the hub cannot be read the MCP pass fails loudly and changes nothing. lost.plus credentials come from `auth`, external-service credentials remain in the passage MCP (`~/.local/bin/harnesses`) | `files/harnesses.sh` |
| `providers` | Provider enrollment, credential mirrors, and model refresh; Grimoire uses `auth`, while third-party provider keys remain in the passage MCP (`~/.local/bin/providers`). A provider dropped from the registry is named in `retired_providers` so every machine sweeps its credential and catalogue instead of keeping them forever (`~/.local/bin/providers`) | `files/providers.sh` |
| `miniharness` | The headless model summon (`npm install -g miniharness`) that `system-updates` asks at 07:00 whether a reboot is safe. Installed globally through npm, so its path follows the active node version rather than a fixed target | `files/miniharness.sh` |
| `tmux` | `tmux` setup with truecolor support, custom status bar, click-to-select, mouse scrolling, title hooks, and the `ssh` reconnect wrapper | `files/tmux.sh` |

The fleet-only `ssh-aliases` module also sets an outbound default of
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

`auth login` performs one browser-approved onboarding for the machine and stores a renewable setup session plus the account's active global or per-service bearer set locally with mode `0600`. It reports the machine hostname during login and later refreshes so Auth can identify each setup device without exposing its network address in the console. `auth status`, `auth refresh`, and `auth token` sync through `/api/setup/session/token`, so bearer rotations, revocations, token-mode changes, and admission changes arrive without another browser login. The local bundle and setup-managed consumer copies are bound to the Auth origin and immutable account subject. A confirmed session rejection is remembered and fails closed; temporary Auth unavailability may use the last-known-good bearer while that session remains active. Setup sessions and bearer tokens are separately revokable in Auth. `auth token` uses distinct exit statuses for authoritative absence, rejected setup sessions, and temporary failures, allowing `providers` and `harnesses` to remove only confirmed revoked managed mirrors while preserving same-account copies during outages or temporary unreadability. During MCP reconciliation, each declared credential source is authoritative; an existing environment or `.zshenv` value is used only as a last-known-good fallback when its source is unavailable. The module is available outside the trusted fleet boundary; Auth account admission still determines which service credentials a user can receive.

---

`harnesses settings` and `harnesses mcp` discover the newest numeric version of the local `unified-computer-use` Codex plugin on macOS, under `~/.codex/plugins/cache/openai-bundled`. The manifest's `localPluginMcpServers` entry imports `cua_repl` as Claude's user-scope `cua_repl` stdio server, copying its command, arguments, and environment. The daily refresh updates that registration when the installed plugin changes. ChatGPT and its computer-use components must already be installed and permitted on the Mac; setup does not install them. Linux skips this entry. Missing, malformed, disabled, or unavailable plugin launch settings are reported and leave an existing Claude registration alone; local/project registrations retain precedence. This integration uses the app's unofficial plugin interface and may need adjustment after app updates. Codex continues to use its own plugin.

`harnesses refresh` runs daily at 11:00 and can overlap the hourly provider refresh and active T3 sessions. Its Claude MCP management and self-update commands run with `CLAUDE_CODE_SIMPLE=1` only in their child environment: normal Claude startup can refresh OAuth even for these administrative commands, and a rejected refresh can erase the shared login. Minimal mode preserves MCP configuration management and updates while skipping native OAuth reads. Interactive Claude and T3 sessions retain their normal authentication behavior.

## Detailed Feature Overview

### AI Tools Integration

- **`agents`**: Deploys standard AI instructions (`AGENTS.md`) and skills to `~/.agents/`, and symlinks them into Claude Code (`~/.claude/`), Codex (`~/.codex/`), Antigravity (`~/.gemini/`), OpenCode (`~/.config/opencode/`), Muse Code (`~/.config/muse/`), and the home directory.
- **`resume`**: Scans active and previous sessions across Claude Code, Codex, OpenCode, Antigravity CLI, ForgeCode, Hermes, Grok, Kimi Code, and Muse Code so you can jump right back into any session.
- **`opencodex`**: Profile launcher that manages custom API keys, OAuth sessions, model aliases, and provider endpoints across multiple AI tools.
- **Mixed-tier admission policy**: a provider descriptor may carry `model_allow_ids`, `model_allow_suffixes`, and `model_no_reasoning_suffixes`, which admit only known-free or newly published `-free`/`alpha` model IDs into the mirrored catalogs and keep `alpha` IDs off OpenCodex's generic reasoning ladder. OpenCode Zen used all three; it has since been retired, so no live provider sets them, and they remain for the next mixed free/paid endpoint.
- **Retiring a provider**: deleting a provider from the registry is not enough, because every consumer write path is an upsert — the credential and model list would sit on each machine forever. Name it in `retired_providers` and each refresh sweeps it out of the credential cache, the `.zshenv` key block, opencode's `auth.json` and provider block, the provider state, the capability cache, Hermes, and Pi. A name that is itself live, or that a live provider borrows as its credential, is rejected at validation.
- **OpenCode Go session affinity**: `opencodex` carries the stable request/conversation lane required by OpenCode's routes as `x-opencode-session`. This is upstream behaviour — setup used to patch the installed runtime to extend it to OpenCode Zen as well, but Zen is retired and OpenCodex 2.59.0 rewrote that transport, so the patch is gone and the runtime is installed verbatim.
- **Harness updates**: `setup update` also self-updates every installed AI harness — Claude Code, Codex, OpenCode, Antigravity, Hermes, Grok, Kimi, Muse, and T3 Code. Each harness is a self-installing tool rather than a setup module, so setup locates it and runs its own updater (`claude update`, `opencode upgrade`, `hermes update --yes`, and so on). Muse has no update subcommand, so setup forces its launcher to refresh synchronously with `MUSE_SYNC_UPDATE=1 muse --version`. T3 Code is updated with `t3 update --yes`, which also moves its background service and briefly restarts it; a Linux host set up through npx has no `~/.local/bin/t3`, so setup runs the newest `~/.t3/runtime/versions/*/t3` instead. Harnesses missing from the machine are skipped. `harnesses install <name>` installs any of them on Linux or macOS with the harness's own first-party installer (`t3` also installs its background service; linking T3 Connect stays a manual `t3 connect`); a bare `harnesses install` only installs the harnesses the manifest marks `default` (Claude Code and Codex). The copy it updates is the copy the operator's shell would run: a machine that has run `nvm install` more than once keeps a `codex` and a `claude` under every node version it still has, so the run puts the operator's own bin directories at the front of `PATH` and the node toolchains behind it on the end — those are there to be found, not to win (an unused newer node used to shadow `~/.local/bin`, and the run then upgraded a stale copy nobody starts) — and it hands each self-updater the `npm` belonging to the install its own executable lives in, since `codex update` and `claude update` shell out to `npm install -g` and any other `npm` would install somewhere else. An updater exiting 0 is not taken as proof that it did anything: the run reads each harness's `--version` before and after and prints either the transition or `(unchanged)`, then names the unchanged harnesses at the end. Usually that just means the machine was already current, but it is also what a stuck updater looks like -- a Homebrew-managed opencode answers `opencode upgrade` with "already installed" and exits 0 while a newer release sits in the tap. The module owns its own cadence: `harnesses schedule` installs a daily 07:00 timer (an hour clear of the 06:00 `setup schedule` timer) that runs `harnesses update`, and `setup enable harnesses` / `setup disable harnesses` drive that timer. `setup update` only updates modules, so `setup update harnesses` updates the harnesses module itself like any other filter. Unattended runs defer any module update that needs an interactive administrator prompt and report the command to run later in a terminal.
- **MCP tokens for Claude, however it was launched**: a `claude` started by a service or a GUI app (T3 Code under systemd or launchd, an app opened from the Dock) never reads `~/.zshenv`, so a `${JINA_MCP_TOKEN}` header expanded to nothing and every token server answered 401. `harnesses mcp` therefore enrolls each token server in Claude with a `headersHelper`, `harnesses mcp-headers <bearer|x-api-key> <VAR>`, which Claude runs at every connect: it reads that one token from the `harnesses:mcp-tokens` block of `~/.zshenv` and prints the header as JSON. The secret lives only in `.zshenv`, the same on macOS and Linux, and a rotated token reaches Claude on its next reconnect. Codex has no released equivalent yet (`http_headers_helper` is on codex main), so for now `harnesses mcp` also mirrors the token block into `~/.codex/.env` (mode 600), which codex loads itself however it was launched; that copy goes once an installed codex has the helper.

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
