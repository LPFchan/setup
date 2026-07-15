# AGENTS

Canonical agent instructions for the fleet. `~/.claude/CLAUDE.md`,
`~/.codex/AGENTS.md`, and `~/AGENTS.md` symlink to this file. Managed by the
`agents` module in LPFchan/setup — edit it there and run `setup update` to sync
every machine.

Fleet topology (machines, hosts, roles): see `fleet` skill (agents/skills/fleet/SKILL.md).

## Harness-specific rules

- **hermes**: use `background=true` + `notify_on_complete=true` for long-running
  terminal tasks (builds, downloads, training, data processing).
- **opencode**: use `nohup` for long-running terminal tasks (survives the tool
  timeout). Config: `~/.config/opencode/opencode.json`.

      nohup <command> > /tmp/<task>.log 2>&1 &
      echo $!   # PID for monitoring

## General rules

- Global skills load from `~/.agents/skills/`.
- Python: always use the repo-local `.venv` and its pip. Never
  `--break-system-packages` on system Python. Use `pipx` if a global install is
  needed.
- RTK bypass: `sudo rtk <cmd>` can fail with `rtk: command not found` (sudo's
  minimal PATH) — use the real binary: `/usr/bin/docker`, `/usr/bin/git`, …

## Problem-solving

- **Search before debugging.** On a bug or blocker, first search the relevant
  repo's GitHub issues/PRs, then web search/fetch (Google, docs, forums), then
  `conversation_recall` for prior sessions. Only then start your own
  investigation. If web search is unavailable, tell the user.
- **Backtrack after a hard fix.** If remedies A…F were tried and F finally
  worked, isolate whether A–E actually contributed (one-by-one variable
  isolation). Revert the ones that didn't, unless they're proven to fix other
  bugs or regressions.
