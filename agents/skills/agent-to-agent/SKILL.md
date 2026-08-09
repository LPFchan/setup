---
name: agent-to-agent
description: Agent-to-agent (a2a) delegation invokes another coding-agent harness as a subagent and continues the same delegated conversation across turns. Use when an agent needs to summon Codex, Claude Code, OpenCode, Antigravity CLI, Hermes Agent, Grok Build, Kimi Code CLI, Muse Code, or OpenCodex (routing a child onto another provider's model) through a shell or terminal tool, retain the child session, send follow-up instructions, or coordinate ongoing agent-to-agent work.
---

# Agent to Agent

Delegate a bounded task from one agent harness to another while retaining the
child harness's session identifier for follow-up turns.

## Parent control contract

Every delegation exposes the same four parent operations, even when the
target harness implements some of them only through a broker or an
interrupt/resume fallback:

- **OBSERVE** — consume live events and terminal state. Process liveness means
  only that the child still exists; a new event is evidence of progress.
- **STEER** — deliver best-effort guidance to the active turn. A successful
  write or RPC means accepted, not applied. If the harness has no live-input
  path, record the instruction and use interrupt/resume for urgent redirects.
- **QUEUE** — persist next-turn messages in FIFO order before acknowledging
  them. Drain one message at a time only after the active turn reaches a
  terminal state. A harness's in-memory input buffer is not a durable queue.
- **INTERRUPT** — cancel the exact active turn or process, wait for terminal
  confirmation, then optionally resume with a queued or superseding
  instruction. Completed tool calls and external side effects are not rolled
  back.

Keep one logical mutating controller per child session. Retain explicit child,
thread, turn, process, and message IDs; serialize all mutations; and never
start or resume two turns for the same session concurrently. Treat an
`item/completed`, tool-result, or similar event as observation, not as a
scheduling barrier: the child may already have started its next action. Each
target reference labels which controls are native and which are broker
responsibilities.

For broker-owned records, use the states `pending -> in_flight -> applied`.
Durably commit `pending -> in_flight` before submitting a message. On recovery,
transactionally convert every recovered `in_flight` row without terminal
evidence to `unknown` before draining anything; do not automatically replay an
`unknown` record because the child may already have applied side effects.
Resolve an `unknown` record by inspection or operator decision. For an urgent
redirect, one committed transaction must mark every displaced `pending` record
`superseded` and insert or promote the redirect before the controller
interrupts the child or acknowledges the redirect. Never silently jump over
older pending records. A redirect does not undo side effects from an
interrupted turn.

Permission requests are control events, not progress or terminal state. A
headless broker must answer each reverse permission request with an
operator-authorized policy (or deliberately use the harness's documented
unattended mode); never leave a tool call waiting for an interactive client.

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

### Antigravity CLI

When Antigravity CLI is the orchestrator, launch the external harness as a
persistent background terminal task and monitor it through the task manager.
Retain the task identifier until the process exits.

### Hermes Agent

When Hermes is the orchestrator, call its terminal tool with `background=true`
and `notify_on_complete=true`. Retain the returned process session ID and use
the process tool's `poll`, `log`, `wait`, and `kill` actions for lifecycle
control. Do not use shell-level `nohup` or `&`; native background execution
keeps the process observable and preserves completion notification.

This workflow runs a resumable external child-harness session. Hermes's native
`delegate_task` is useful for ordinary delegation, but is not a substitute when
the parent must retain and explicitly resume an external child conversation.

### Kimi Code CLI

When Kimi Code is the orchestrator, pass `run_in_background=true` on the Bash
tool call; never `nohup`. The run is exempt from the foreground timeout,
persists across turns, and a completion notification arrives automatically
when the process exits. Output can be read mid-run with TaskOutput, and
TaskStop cancels the child.

### Muse Code

When Muse Code is the orchestrator, run the child through managed bash and let
the runtime background it: a command that outlives the foreground budget
becomes a background task terminal on its own, and its final result is
delivered as runtime context after the turn ends. Never background it yourself
with `nohup` or `&` — unmanaged shell backgrounding is rejected. Do not poll a
backgrounded command for completion; retain the bash session id and use it only
to feed input to a live process, or when a runtime overdue notice names that
session. `/tasks` lists running tasks and terminals.

## Select the target

- For Codex, read [references/codex.md](references/codex.md) and follow it.
- For Claude Code, read [references/claude-code.md](references/claude-code.md)
  and follow it.
- For OpenCode, read [references/opencode.md](references/opencode.md) and
  follow it.
- For Antigravity CLI (`agy`), read
  [references/antigravity.md](references/antigravity.md) and follow it.
- For Hermes Agent, read [references/hermes.md](references/hermes.md) and
  follow it.
- For Grok Build, read [references/grok.md](references/grok.md) and follow it.
- For Kimi Code CLI, read [references/kimi.md](references/kimi.md) and follow
  it.
- For Muse Code, read [references/muse.md](references/muse.md) and follow it.
- To run a child on a model its own harness cannot reach — a provider routed
  through the local OpenCodex proxy — read
  [references/opencodex.md](references/opencodex.md) and follow it. OpenCodex
  is a wrapper that launches `claude`, `codex`, `grok`, or `kimi` against the
  chosen route, so the leg's own reference still governs the conversation.

Keep one child session per delegated task. Give the child the goal, working
directory, relevant context, constraints, and expected result. Review its
output before relying on it or applying consequential actions.
