---
name: proactive-docs
version: 1.0
description: Keep documentation fresh after a change by routing each edit to its one canonical surface. Trigger whenever you change shell/ssh config, an AI harness or MCP server, backup/kernel/monitoring setup, a `setup` module, a repo-template scaffold or skill, agent rules (AGENTS/FLEET/skills), or GPU/inference infra — i.e. any config, module, or workflow that has a documented home.
argument-hint: "The change you just made (files touched, subsystem affected)"
audience: fleet
---

# Proactive Docs

Use this skill right after you change something that is documented, to update the
one surface that owns that documentation — before the doc goes stale. The point
is single-sourcing: every fact lives in exactly one place, and you update *that*
place, not a copy of it.

## Three surfaces, three owners

| Surface | Owns | Update it when you change… |
| --- | --- | --- |
| **`LPFchan/setup`** | code/config truth: module scripts (`bin/`, `files/`), managed-block bodies, `manifest.tsv`, the canonical `agents/` payload (`AGENTS.md`, `FLEET.md`, `skills/`) | a module's behavior, a managed block, an agent rule, the fleet topology, or a global skill |
| **`LPFchan/repo-template`** | the repo operating system: `scaffold/` (records, hooks, `AGENTS.md` shim) and repo-scoped skills | how projects are scaffolded, the commit contract, hooks, or a repo-scoped skill |
| **`linux-setup/` (Obsidian)** | operator field notes — only what the repos don't capture: bootstrap/operate runbooks, harness + MCP wiring, per-subsystem gotchas | how you *install, wire, or troubleshoot* a machine (steps, runbooks, gotchas) — never module internals |

GPU/inference infra has its own home: Obsidian `inference/`.

## The routing rule

For each thing you changed, ask **"which surface is canonical for this fact?"**
and update only that one:

- Changed a **module's code or a managed block**? → edit the source in
  `LPFchan/setup`. The Obsidian doc covers *usage*, not internals — leave it
  unless the usage changed.
- Changed an **agent rule, the fleet, or a global skill**? → edit
  `setup/agents/…`. It syncs to every machine via `setup update`. Do **not**
  also write it into Obsidian — that content was deliberately removed from the
  operator notes.
- Changed **repo scaffolding or a repo-scoped skill**? → `LPFchan/repo-template`.
- Changed **how you set up or operate a box** (a harness install step, an MCP
  registration, a restore runbook, a kernel-policy tweak, a shell/ssh gotcha)?
  → the matching `linux-setup/` doc:

  | You touched | Obsidian doc |
  | --- | --- |
  | AI harness install · MCP server · yolo · RTK | `01-harnesses.md` |
  | shell config gotchas · ssh key registration / DSM | `02-shell-ssh.md` |
  | backup · kernel-simmer/updates · monitoring/fans | `03-server-ops.md` |
  | bootstrap / first-run / a new module exists | `00-overview.md` |
  | GPU / inference | `inference/*.md` |

## Rules

- **One fact, one home.** Never mirror the same fact across surfaces. If it's
  canonical in a repo, the Obsidian note does not restate it — and vice versa.
- **Delete, don't point.** When content becomes fully repo-canonical, remove it
  from Obsidian rather than leaving a "see the repo" stub.
- **Keep operator notes to residue.** In `linux-setup/`, keep only what a person
  actually does or needs when setting up / operating a box (commands, runbooks,
  gotchas). Cut command tables that duplicate module `--help`, changelogs, and
  post-mortem forensics — those live in the repo and its commit history.
- **Research-only notes are exempt.** Point-in-time snapshots (benchmarks,
  security audits, packet captures) are historical, not living docs — do not
  proactively update them.

## Skip when

- The change is purely local/experimental and not yet a durable decision.
- The fact is already single-sourced in the surface you edited (nothing to sync).
