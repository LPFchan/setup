# Codex

Use `codex app-server` when the parent needs live control. Use `codex exec` for
the first turn and `codex exec resume` for follow-ups when one-shot execution
is sufficient; each command may run in a separate Bash tool call and the saved
thread carries the conversation.

## Live control with app-server

Start `codex app-server` as one long-lived child process and speak JSON-RPC
over its stdin/stdout. Initialize the connection before creating or resuming a
thread, then start a turn:

```jsonl
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"a2a-broker","version":"1.0.0"}}}
{"method":"initialized","params":{}}
{"method":"thread/start","id":2,"params":{"cwd":"/absolute/path/to/workspace","approvalPolicy":"never","sandbox":"workspace-write"}}
{"method":"turn/start","id":3,"params":{"threadId":"THREAD_ID","input":[{"type":"text","text":"DELEGATED TASK"}]}}
```

For an existing conversation, send `thread/resume` with its explicit
`threadId` in place of `thread/start`. Keep the server process, connection,
`threadId`, and active `turnId` together in parent state.

- **OBSERVE (native):** consume `thread/started`, `turn/started`,
  `item/started`, item-specific delta notifications, `item/completed`, and
  `turn/completed`. Use the process state for liveness and event arrival for
  progress. Only `turn/completed` is a turn boundary.
- **STEER (native, best effort):** send `turn/steer` with `threadId`, the exact
  active `expectedTurnId`, and `input`. The response confirms acceptance by
  that turn; it does not prove when the model applied the guidance and does
  not emit another `turn/started`.
- **QUEUE (broker):** persist messages with stable IDs in FIFO order and track
  `pending`, `in_flight`, `applied`, and `unknown` delivery states. Send them
  with `turn/start` only after `turn/completed`; never replay `unknown`
  automatically and do not use concurrent `turn/start` calls as a queue. For
  an urgent redirect, mark displaced pending records `superseded` under the
  broker lock before interrupting and promoting the redirect.
- **INTERRUPT (native):** send `turn/interrupt` with `threadId` and `turnId`,
  then wait for `turn/completed` whose turn status is `interrupted` before
  starting another turn.

```jsonl
{"method":"turn/steer","id":4,"params":{"threadId":"THREAD_ID","expectedTurnId":"TURN_ID","input":[{"type":"text","text":"STEERING INSTRUCTION"}]}}
{"method":"turn/interrupt","id":5,"params":{"threadId":"THREAD_ID","turnId":"TURN_ID"}}
```

An `item/completed` notification is not an exact between-tool checkpoint. If
the parent must gate the next tool, design the child prompt to stop at an
explicit checkpoint and wait for a later turn.

## Available Models

Probe the current Codex model catalog before selecting a model or reasoning
effort:

```bash
codex debug models |
  jq -r '
    .models[]
    | select(.visibility == "list")
    | [
        .slug,
        .default_reasoning_level,
        ([.supported_reasoning_levels[].effort] | join(","))
      ]
    | @tsv
  '
```

The columns are model slug, default effort, and supported efforts.

## Choose the model and effort

The parent may pin both when starting the thread:

```bash
model=gpt-5.6-sol
effort=medium
```

The blocks below require both variables to be set; to fall back to Codex
defaults instead, delete the flag and its variable together rather than
leaving the variable empty.

## Start a thread

Keep the target workspace separate from temporary orchestration state. Launch
this block in the orchestrator's background terminal:

```bash
workdir=/absolute/path/to/workspace
model=gpt-5.6-sol
effort=medium
run_id="$(uuidgen)"
run_dir="/tmp/codex-${run_id}"
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
final_file="$run_dir/${turn}.final.txt"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Inspect the failing tests, identify the cause, and report a minimal fix plan. Do not edit yet.'

mkdir "$run_dir" || exit 1
printf 'run_dir=%s\n' "$run_dir"

printf '%s' "$prompt" |
  codex \
    --search \
    --sandbox workspace-write \
    --ask-for-approval never \
    exec --json \
    --output-last-message "$final_file" \
    --model "$model" \
    -c "model_reasoning_effort=\"$effort\"" \
    --skip-git-repo-check \
    -C "$workdir" \
    - \
    >"$events_file" \
    2>"$stderr_file"
run_status=$?

thread_id="$(jq -r 'select(.type == "thread.started") | .thread_id' "$events_file" | head -n 1)"
[[ "$thread_id" =~ ^[0-9a-f-]{36}$ ]] || { printf 'no thread id\n' >&2; exit 1; }
printf 'thread_id=%s\n' "$thread_id"

terminal="$(jq -r 'select(.type == "turn.completed" or .type == "turn.failed"
  or .type == "error") | .type' "$events_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || "$terminal" != "turn.completed" ]]; then
  printf 'turn failed: status=%s terminal=%s\n' "$run_status" "${terminal:-none}" >&2
  exit 1
fi

[[ -f "$final_file" ]] && cat "$final_file"
exit "$run_status"
```

Retain `run_id`, `run_dir`, the background terminal identifier, and `thread_id`
in the parent agent's task state. Raw JSONL and stderr remain in `run_dir`, one
timestamped set per turn; only the identifiers and final response enter the
parent agent's context.

## Continue the thread

Send every correction, question, or next step to the same thread:

```bash
run_dir=/tmp/codex-RETAINED_RUN_ID
thread_id=RETAINED_THREAD_ID
model=gpt-5.6-sol
effort=medium
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
final_file="$run_dir/${turn}.final.txt"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Implement the plan, run the focused tests, and report changed files and verification results.'

printf '%s' "$prompt" |
  codex \
    --search \
    --sandbox workspace-write \
    --ask-for-approval never \
    exec resume --json \
    --output-last-message "$final_file" \
    --model "$model" \
    -c "model_reasoning_effort=\"$effort\"" \
    --skip-git-repo-check \
    "$thread_id" \
    - \
    >"$events_file" \
    2>"$stderr_file"
run_status=$?

terminal="$(jq -r 'select(.type == "turn.completed" or .type == "turn.failed"
  or .type == "error") | .type' "$events_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || "$terminal" != "turn.completed" ]]; then
  printf 'turn failed: status=%s terminal=%s\n' "$run_status" "${terminal:-none}" >&2
  exit 1
fi

[[ -f "$final_file" ]] && cat "$final_file"
exit "$run_status"
```

Repeat `codex exec resume` until the delegated task is complete.

Pass the model and effort on every resumed turn so separate CLI invocations use
the same settings. Change either variable deliberately when a later turn needs a
different tradeoff.

## Monitor a running turn

Poll the background terminal for process status. To inspect progress without
loading raw event bodies into the parent agent's context, run this against the
current `events_file`:

```bash
events_file="$(ls -t /tmp/codex-RETAINED_RUN_ID/*.events.jsonl | head -n 1)"

jq -Rr '
  fromjson?
  | if .type == "thread.started" then
      "thread.started \(.thread_id)"
    elif .type == "turn.started"
      or .type == "turn.completed"
      or .type == "turn.failed"
      or .type == "error" then
      .type
    elif .type == "item.started" or .type == "item.completed" then
      "\(.type) \(.item.type) \(.item.status // "")"
    else
      empty
    end
' "$events_file" | tail -n 20
```

Interpret Codex JSONL events as follows:

| Signal | Meaning |
| --- | --- |
| `thread.started` | Capture the thread ID for later turns. |
| `turn.started` | Codex accepted and began the turn. |
| `item.started` or `item.completed` | Codex began or finished a reasoning, message, command, file-change, MCP, web-search, or plan item. |
| Agent-message item | Codex sent an intentional progress update or response. |
| `turn.completed` | The turn completed successfully. |
| `turn.failed` or `error` | The turn failed. |

A newly received event proves progress. A live process with no new event proves
only liveness: Codex may be reasoning, waiting on a model response, blocked in a
tool, or stalled. Codex cannot guarantee periodic messages during those waits,
so never declare a stall from silence alone.

Use the orchestrator's process/task status as a liveness signal and JSONL events
as progress signals. Apply a generous hard deadline when runtime must be
bounded, and never resume the same thread while its current turn is still live.

Treat process exit without a terminal JSONL event as an interruption and recover
as described in Interrupting and Redirecting.

## Interrupting and Redirecting

A live `codex exec` fallback turn accepts no follow-up input. To interrupt it gracefully,
use the orchestrator's native background-terminal facility to send Ctrl-C or
SIGINT to the foreground process. Codex translates SIGINT into an internal
`turn/interrupt` request and waits for the interrupted turn to shut down.

Confirm that the process exited before resuming the thread. If graceful
interruption does not finish, use the orchestrator's native force-stop facility
for the background task and confirm its process tree is no longer running. Keep
`run_dir` for diagnostics when the process exits without a terminal JSONL event.

Then send the next turn with `codex exec resume "$thread_id"` as usual:

- To recover from an involuntary interruption, instruct the child to continue
  where it left off.
- To redirect, state the new instruction and that the previous one is
  superseded.

The thread can be resumed only after `thread_id` has been captured. Commands and
file changes completed before interruption have already taken effect, so tell
the child it was interrupted mid-task and to reassess the workspace before
continuing.

## Rules

- Choose an effort supported by the selected model; Codex rejects unsupported
  combinations.
- Use an explicit `thread_id`; never use `resume --last` when agents may run concurrently.
- Never add `--ephemeral`; ephemeral runs cannot be resumed.
- Do not resume the same thread concurrently.
- Use `workspace-write` by default; reduce it to `read-only` when the task does
  not need edits. Do not use `danger-full-access` or bypass the sandbox unless
  the parent is already inside a trusted external sandbox and the operator
  authorized it.
- Pass prompts through stdin and quote shell variables. This prevents shell
  injection; it does not make untrusted prompt content safe.
- Treat a nonzero exit or a JSONL `turn.failed`/`error` event as an unsuccessful
  turn. Handle a requested interruption as described above; never present a
  partial agent message as success.

## Clean up

Keep `run_dir` while the delegated conversation may receive follow-up turns.
After the parent has received the final response and the delegation is complete,
the parent may remove `run_dir` using its own safe cleanup mechanism.

Retain the directory after a failed turn until its JSONL and stderr have been
inspected. Removing it does not delete the persisted Codex conversation under
`~/.codex/sessions`; it removes only this delegation's temporary telemetry,
stderr, and final-response file.
