---
name: proactive-docs
version: 1.0
description: Keep documentation fresh after a change by routing each edit to its one canonical surface. Trigger whenever you change shell/SSH config, an AI harness or MCP server, backup/kernel/monitoring setup, a setup module, application or repo-template behavior, agent rules or skills, or GPU/inference infrastructure.
argument-hint: "The change you just made (files touched, subsystem affected)"
audience: fleet
---

# Proactive Docs

After changing documented behavior, update its single canonical owner.

## Choose the Owner

| Surface | Owns |
| --- | --- |
| `LPFchan/setup` | Module code/config and the global `agents/` payload |
| `LPFchan/repo-template` | Scaffolding, repo contracts, hooks, and repo-scoped skills |
| Application repo | Its implementation, runtime config, spec, status, decisions, research, and tests |
| `linux-setup/` (Obsidian) | Operator-only bootstrap or wiring absent from every repo and global skill |

Route the change:

- Module, managed block, global agent rule, fleet topology, or global skill →
  `setup`.
- Scaffold, commit contract, hook, or repo-scoped skill → `repo-template`.
- Application behavior or config → that application's canonical repo surface.
- Operator-only machine setup with no repo/skill owner → the matching Obsidian
  note:

  | Topic | Note |
  | --- | --- |
  | Harness install, MCP registration, yolo, RTK | `01-harnesses.md` |
  | Shell and SSH | `02-shell-ssh.md` |
  | Backup, kernel, monitoring, fans | `03-server-ops.md` |
  | Bootstrap or first run | `00-overview.md` |

## Grimoire and ComfyUI

| Fact | Owner |
| --- | --- |
| Code, Docker/Compose, registry implementation, spec/status/decisions/research | `/home/yeowool/grimoire/` canonical repo surface |
| Fleet operating procedure: endpoints, presets, lifecycle, intake, forks, upgrades, incidents, ComfyUI co-tenancy | `setup/agents/skills/grimoire/` |
| Eastself training workflow | `/home/yeowool/Eastself/` canonical guide or repo surface |

Do not recreate `inference/` notes for these facts.

## Rules

- **One fact, one home.** Never mirror repo or skill content into Obsidian.
- **Delete, don't point.** Remove fully canonicalized Obsidian content; do not
  leave “see the repo” stubs.
- **Keep operator notes to residue.** Remove copied command help, implementation
  detail, changelogs, and post-mortem forensics.
- **Keep secrets in Vaultwarden.** Documentation may name a secret item, never
  contain its value.
- **Preserve research snapshots.** Point-in-time benchmarks, audits, and packet
  captures are historical rather than living documentation.

## Skip

Skip documentation work when the change is experimental or already updates its
only canonical surface.
