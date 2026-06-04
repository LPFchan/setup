# linux-setup

Curl-installable setup files for personal Linux/macOS machines.

This repo is the source of truth for live scripts and generated config. Obsidian stays documentation-only and should link here instead of embedding full script bodies.

## Install

Install the updater CLI:

```bash
curl -fsSL https://setup.lost.plus/install.sh | bash
```

The bare installer installs `linux-setup`, `resume`, and `ai-menu`, then idempotently wires shell startup for zsh and bash:

```text
~/.zshenv                  PATH only
~/.zshrc                   interactive ai auto-launch
~/.bashrc                  PATH + interactive ai auto-launch
~/.bash_profile            only when no bash login profile exists
```

Managed blocks are marker-delimited as `linux-setup:<label>` and are safe to rerun. Existing unmarked PATH or `ai-start-menu` + `AI_AUTO_LAUNCHED` setup is detected and left alone.

Install managed modules explicitly:

```bash
linux-setup install resume ai-menu
```

Update installed modules later:

```bash
linux-setup update
```

## Commands

```bash
linux-setup list
linux-setup install resume ai-menu
linux-setup update
linux-setup uninstall
linux-setup diff resume
linux-setup doctor
```

## Drift Policy

Managed files carry version metadata in the file itself:

```bash
# linux-setup-module: resume
# linux-setup-version: 2026.06.05.1
# linux-setup-source: files/resume
```

`linux-setup update` fetches the remote file, reads its version, compares it with the local file version, and installs only when the remote version is newer or the local file is missing.

Installed files are also tracked by SHA-256 in `~/.local/state/linux-setup/installed.tsv`. Updates replace a file automatically only when it still matches the last installed hash.

If a local file has been edited, `linux-setup` writes the new version beside it as `<path>.new` unless `--force` is used.

## Modules

| module | target | source |
|---|---|---|
| `linux-setup` | `~/.local/bin/linux-setup` | `bin/linux-setup` |
| `resume` | `~/.local/bin/resume` | `files/resume` |
| `ai-menu` | `~/.bashrc.d/ai-start-menu` | `files/ai-start-menu` |

## Uninstall

Remove all managed files and marker-managed shell config blocks:

```bash
linux-setup uninstall
```

Remove selected modules only:

```bash
linux-setup uninstall resume ai-menu
```

If a managed file has local edits, uninstall keeps it unless `--force` is used.

## Design

- GitHub is the canonical code host.
- GitHub Pages serves the public installer at `https://setup.lost.plus`.
- `install.sh` only bootstraps the updater CLI.
- `manifest.tsv` declares module, target path, mode, and source path.
- Each managed source file declares its own module and version.
- Obsidian documents behavior and links to canonical files here.
- Secrets do not belong in this repo.

## Development

Use the local checkout as the source root while testing:

```bash
LINUX_SETUP_BASE_URL=file://$PWD ./bin/linux-setup update resume ai-menu
```

The raw GitHub URL also works as a fallback:

```bash
LINUX_SETUP_BASE_URL=https://raw.githubusercontent.com/LPFchan/linux-setup/main linux-setup update
```
