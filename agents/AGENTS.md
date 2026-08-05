# AGENTS

Canonical agent instructions for the fleet. `~/.claude/CLAUDE.md`,
`~/.codex/AGENTS.md`, `~/.gemini/GEMINI.md`, `~/.config/opencode/AGENTS.md`,
`~/.config/muse/AGENTS.md`, and `~/AGENTS.md` symlink to this file. Managed by
the `agents` module in LPFchan/setup — edit it there and run `setup update` to
sync every machine.

Fleet topology (machines, hosts, roles): see `fleet` skill (agents/skills/fleet/SKILL.md).

## Harness-specific rules

- **hermes**: use `background=true` + `notify_on_complete=true` for long-running
  terminal tasks (builds, downloads, training, data processing).
- **kimi**: use `run_in_background=true` on the Bash tool for long-running
  terminal tasks; completion notifications arrive automatically.
- **opencode**: use `nohup` for long-running terminal tasks (survives the tool
  timeout). Config: `~/.config/opencode/opencode.json`.

      nohup <command> > /tmp/<task>.log 2>&1 &
      echo $!   # PID for monitoring
- **antigravity (`agy`)**: use persistent background terminal tasks for
  long-running commands and monitor them with the task manager.
- **muse**: run long tasks through managed bash and let the runtime background
  them — a command that outlives the foreground budget becomes a background
  task terminal on its own, and its result arrives as runtime context after the
  turn ends. Never `nohup` or `&`; unmanaged shell backgrounding is rejected.
  Don't poll a backgrounded command for completion. `/tasks` lists them.
- **codex**: Lead with the verdict. One or two sentences stating the conclusion, 
  then the explain it as a coherent narrative that supports it. Prioritize the 
  few distinctions that drive the recommendation; omit supporting details that 
  do not change it. Use plain language, short sections, Avoid repeated source paths, 
  long inventories, and excessive headings unless explicitly requested. Close with 
  an action or recommendation. Offer the concrete next step the user can take.

## General rules

- **Git branches**: never create a branch — feature, temp, or agent worktree —
  unless the user explicitly asks. Commit to the current branch (`main`
  included); if a branch seems warranted, propose it and wait. Do not branch
  "to be safe," to isolate work, or by default. Leftover branches are the user's
  to clean, so don't make them.
- **Git commits**: commit and push in reasonable slices autonomously; do not
  gate them behind operator input.
- Global skills load from `~/.agents/skills/`.
- Python: always use the repo-local `.venv` and its pip. Never
  `--break-system-packages` on system Python. Use `pipx` if a global install is
  needed.
- RTK bypass: `sudo rtk <cmd>` can fail with `rtk: command not found` (sudo's
  minimal PATH) — use the real binary: `/usr/bin/docker`, `/usr/bin/git`, …

## Problem-solving procedure

- **Search before debugging.** On a bug or blocker, first search the relevant
  repo's GitHub issues/PRs, then web search/fetch (Google, docs, forums), then
  `conversation_recall` for prior sessions. Only then start your own
  investigation. If web search is unavailable, tell the user.
- **Backtrack after a hard fix.** If remedies A…F were tried and F finally
  worked, isolate whether A–E actually contributed (one-by-one variable
  isolation). Revert the ones that didn't, unless they're proven to fix other
  bugs or regressions.
