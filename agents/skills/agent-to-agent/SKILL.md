---
name: agent-to-agent
description: Invoke another coding-agent harness as a subagent and continue the same delegated conversation across turns. Use when an agent needs to summon Codex, Claude Code, or OpenCode through a shell or Bash tool, retain the child session, send follow-up instructions, or coordinate ongoing agent-to-agent work.
version: 1.0.0
argument-hint: <codex|claude-code|opencode> [task to delegate]
---

# Agent to Agent

Delegate a bounded task from one agent harness to another while retaining the
child harness's session identifier for follow-up turns.

## Run children asynchronously

Start potentially long-running children with the orchestrator's native
background facility so a foreground shell timeout cannot terminate them. Keep
the returned task or terminal identifier and poll it until completion.

Treat backgrounding as process-lifetime management, not proof of progress.
Follow the target harness reference for its progress and terminal-state signals.

### Codex

When Codex is the orchestrator, launch the external harness in a tool-managed
background terminal. It continues after the initiating tool call returns and
can be inspected later.

### Claude Code

When Claude Code is the orchestrator, pass `run_in_background: true` on the
Bash tool call; never `nohup`. The run is exempt from the foreground timeout,
persists across turns, and re-invokes the agent when the process exits.
Incremental output can be read on demand mid-run (TaskOutput), or a Monitor
can watch the log for a condition.

### OpenCode

When OpenCode is the orchestrator, the Bash tool blocks until the child exits
or the timeout fires (default 120 s). There is no native background facility.
If the child may exceed the timeout, launch it in a new tmux window in the
orchestrator's main session and poll its output file for progress; see the
target's reference for its event format and progress signals.

## Select the target

- For Codex, read [references/codex.md](references/codex.md) and follow it.
- For Claude Code, read [references/claude-code.md](references/claude-code.md)
  and follow it.
- For OpenCode, read [references/opencode.md](references/opencode.md) and
  follow it.

Keep one child session per delegated task. Give the child the goal, working
directory, relevant context, constraints, and expected result. Review its
output before relying on it or applying consequential actions.
