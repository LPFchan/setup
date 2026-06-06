# linux-setup

Curl-installable setup files for personal Linux/macOS machines.

This repo is the source of truth for live scripts and generated config.

## Install

```bash
curl -fsSL https://setup.lost.plus/install.sh | bash
```

Installs `setup` CLI to `~/.local/bin/`, then runs `setup` (interactive fzf reconfigure) or batch-installs all modules.

## Modules

| module | target | source |
|--------|--------|--------|
| `setup` | `~/.local/bin/setup` | `bin/setup` |
| `resume` | `~/.local/bin/resume` | `files/resume` |
| `ai-menu` | `~/.bashrc.d/ai-start-menu` | `files/ai-start-menu` |
| `kernel-simmer` | `~/.local/bin/kernel-simmer` | `bin/kernel-simmer` |
| `service-ctl` | `~/.local/bin/service-ctl` | `bin/service-ctl` |
| `gpu-fancontrol` | `~/.local/bin/gpu-fancontrol` | `files/gpu-fancontrol` |
| `monitoring` | `~/.local/bin/monitoring` | `files/monitoring` |
| `backup` | `~/.local/bin/backup` | `bin/backup` |

## Commands

```bash
setup list                # list available modules
setup status              # show installed state
setup install resume      # install + enable module
setup uninstall resume    # disable + remove module
setup enable kernel-simmer # enable service module
setup disable backup      # disable service module
setup update              # update installed modules, report new ones
setup diff resume         # show diff against remote
setup                     # interactive fzf reconfigure
```

## Design

- GitHub is the canonical code host.
- GitHub Pages serves the public installer at `https://setup.lost.plus`.
- `install.sh` bootstraps the updater CLI.
- `manifest.tsv` declares module, target path, mode, and source path.
- Each managed source file declares its own module and version.
- Secrets do not belong in this repo.
