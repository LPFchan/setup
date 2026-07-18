# Claude Code

Use `claude -p` for the first turn and `claude -p --resume` for every
follow-up. Each turn is one process whose `stream-json` log is a live progress
feed; the persisted session carries the conversation across turns.

## Available Models

The aliases `fable`, `opus`, `sonnet`, and `haiku` route to the latest
available version of those models. Pass a full model ID only to pin a specific
version.

## Choose the model and effort

The parent may pin both when starting the session:

```bash
model=sonnet
effort=medium
```

Use the lowest effort that reliably fits the task. Valid values are `low`,
`medium`, `high`, `xhigh`, and `max`. The blocks below require both variables
to be set; to fall back to the parent's defaults instead, delete the flag and
its variable together rather than leaving the variable empty.

## Start a session

Keep the target workspace separate from temporary orchestration state.
Pre-assign the session ID so it never has to be parsed out of the output.
Launch this block in the orchestrator's background terminal:

```bash
workdir=/absolute/path/to/workspace
model=sonnet
effort=medium
session_id="$(uuidgen)"
run_dir="/tmp/claude-${session_id}"
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Inspect the failing tests, identify the cause, and report a minimal fix plan. Do not edit yet.'

mkdir "$run_dir" || exit 1
printf 'session_id=%s\nrun_dir=%s\n' "$session_id" "$run_dir"

cd "$workdir" || exit 1

printf '%s' "$prompt" |
  claude -p \
    --session-id "$session_id" \
    --model "$model" \
    --effort "$effort" \
    --dangerously-skip-permissions \
    --output-format stream-json \
    --include-partial-messages \
    --verbose \
    >"$events_file" \
    2>"$stderr_file"
run_status=$?

result="$(jq -c 'select(.type == "result")' "$events_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || -z "$result" || "$(jq -r '.is_error' <<<"$result")" != "false" ]]; then
  printf 'turn failed: status=%s\n' "$run_status" >&2
  exit 1
fi
jq -r 'select((.permission_denials | length) > 0)
  | "permission_denials: \(.permission_denials | length)"' <<<"$result" >&2
jq -r '.result' <<<"$result"
exit "$run_status"
```

`--verbose` is required for `stream-json` output in print mode.

Retain `session_id`, `run_dir`, and the background terminal identifier in the
parent agent's task state. Raw JSONL and stderr remain in `run_dir`, one
timestamped set per turn; only the identifiers and final response enter the
parent agent's context.

## Continue the session

Send every correction, question, or next step to the same session, from the
same working directory:

```bash
workdir=/absolute/path/to/workspace
session_id=RETAINED_SESSION_ID
model=sonnet
effort=medium
run_dir="/tmp/claude-${session_id}"
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Implement the plan, run the focused tests, and report changed files and verification results.'

cd "$workdir" || exit 1

printf '%s' "$prompt" |
  claude -p \
    --resume "$session_id" \
    --model "$model" \
    --effort "$effort" \
    --dangerously-skip-permissions \
    --output-format stream-json \
    --include-partial-messages \
    --verbose \
    >"$events_file" \
    2>"$stderr_file"
run_status=$?

result="$(jq -c 'select(.type == "result")' "$events_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || -z "$result" || "$(jq -r '.is_error' <<<"$result")" != "false" ]]; then
  printf 'turn failed: status=%s\n' "$run_status" >&2
  exit 1
fi
jq -r 'select((.permission_denials | length) > 0)
  | "permission_denials: \(.permission_denials | length)"' <<<"$result" >&2
jq -r '.result' <<<"$result"
exit "$run_status"
```

Repeat `claude -p --resume` until the delegated task is complete.

Pass the model and effort on every resumed turn so separate CLI invocations use
the same settings. Change either variable deliberately when a later turn needs a
different tradeoff.

## Monitor a running turn

Poll the background terminal for process status. To inspect progress without
loading raw event bodies into the parent agent's context, run this against the
current `events_file`:

```bash
events_file="$(ls -t /tmp/claude-RETAINED_SESSION_ID/*.events.jsonl | head -n 1)"

jq -Rr '
  fromjson?
  | if .type == "system" and .subtype == "init" then
      "init model=\(.model)"
    elif .type == "assistant" then
      "assistant \([.message.content[]?.type] | unique | join(","))"
    elif .type == "user" then
      "tool_result"
    elif .type == "result" then
      "result is_error=\(.is_error)"
    else
      empty
    end
' "$events_file" | tail -n 20
```

Interpret Claude Code stream-json events as follows:

| Signal | Meaning |
| --- | --- |
| `init` | Claude accepted the turn; reports the resolved model ID. |
| `assistant` containing `tool_use` | The child invoked a tool. |
| `assistant` containing `text` | The child sent a message or progress update. |
| `assistant` containing `thinking` | The child completed a reasoning block. |
| `user` | A tool result was returned to the child. |
| `stream_event` | Token deltas during generation; excluded from the summary, they register as raw log growth. |
| `result` | The turn ended; `is_error` marks failure. |

A newly appended event proves progress. `--include-partial-messages` keeps
token deltas flowing while the model is generating, but nothing is emitted
between a `tool_use` and its `tool_result` — a long build or test run is
silent for its whole duration. Treat silence as inconclusive: check whether
the last event is an assistant `tool_use` (a tool is likely still running —
inspect its subprocesses), use the orchestrator's process/task status as the
liveness signal, and bound the turn with a generous hard deadline rather than
inferring a stall from quiet alone.

Treat process exit without a `result` event as an interruption and recover as
described in Interrupting and Redirecting.

## Interrupting and Redirecting

A live `-p` turn accepts no input, so interrupting means terminating: stop the
child, confirm it exited, then `--resume` the session with the next
instruction. The session file is append-only at message-completion
granularity, so prior turns and the current turn's completed messages and
tool results survive termination — verified even under SIGKILL — and only the
in-flight increment (an unfinished assistant message, a tool call that had
not returned) is lost.

Prefer the orchestrator's own stop facility for the background terminal; it
terminates the whole process tree. As a shell fallback, locate the child by
its session ID (the UUID on its command line cannot match a reused PID) and
send SIGTERM — Claude Code honors it within seconds and shuts down its own
tool subprocesses. Escalate to SIGKILL only if SIGTERM is not honored, and
then sweep the child's direct tool processes, which SIGKILL orphans:

```bash
pid="$(pgrep -of "claude -p.*${session_id}")" && {
  kill -TERM "$pid" 2>/dev/null
  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && { pkill -KILL -P "$pid"; kill -KILL "$pid"; }
}
```

Do not kill by process group here: unless the child was launched as its own
group leader, it shares the caller's group and a group kill takes out the
orchestrator's shell or terminal with it. Never resume until the process is
confirmed dead.

Then send the next turn with `--resume "$session_id"` as usual:

- To recover from an involuntary interruption (timeout, crash, operator
  stop), instruct the child to continue where it left off.
- To redirect, state the new instruction and that the previous one is
  superseded.

Either way, tool calls that completed before the kill have already taken
effect — files were edited, commands ran — so tell the child it was
interrupted mid-task and the workspace may be partially modified, and to
reassess before continuing.

## Rules

- Always pass `-p`; without it Claude Code starts an interactive TUI that
  hangs the calling tool.
- Sessions are stored per working directory: run every turn from the same
  `workdir`, or grant extra paths with `--add-dir`.
- Use an explicit `--resume "$session_id"`; never use `-c`/`--continue` when
  agents may run concurrently.
- Do not resume a session while its current turn is still live.
- Do not pass `--fork-session` unless the parent deliberately wants a branched
  copy, and never add `--no-session-persistence`; unpersisted runs cannot be
  resumed.
- Headless runs cannot answer permission prompts — a gated tool call is
  silently denied and the child completes with degraded capability.
  `--dangerously-skip-permissions` removes the gates; it also grants the child
  the invoking user's full privileges, so delegate only work the operator
  would run directly, and note the flag refuses to run as root. To keep a host
  gated instead, use `--permission-mode acceptEdits` plus `--allowedTools` for
  the tools the task needs, and treat a non-empty `permission_denials` array
  in the `result` event as a degraded run.
- Pass prompts through stdin and quote shell variables. This prevents shell
  injection; it does not make untrusted prompt content safe.
- Treat a nonzero exit or `"is_error": true` in the `result` event as failure.
  Report it instead of presenting a partial reply as success.

## Clean up

Keep `run_dir` while the delegated conversation may receive follow-up turns.
After the parent has received the final response and the delegation is
complete, the parent may remove `run_dir` using its own safe cleanup
mechanism.

Retain the directory after a failed turn until its JSONL and stderr have been
inspected. Removing it does not delete the persisted conversation under
`~/.claude`; it removes only this delegation's per-turn event log and stderr.
