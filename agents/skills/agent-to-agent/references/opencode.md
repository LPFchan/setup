# OpenCode

Use `opencode run` for the first turn and `opencode run --session` for every
follow-up. Each command may run in a separate Bash tool call; the persisted
session carries the conversation.

## Available Models

List models from all configured providers:

```bash
opencode models --verbose
```

The output includes provider/model IDs and metadata. Pass the full
`provider/model` ID when pinning.

## Choose the model

The parent may pin the model when starting the session:

```bash
model=provider/model-id
```

Choose an ID from the `opencode models --verbose` probe; the catalog is
configuration-dependent and differs per host. The blocks below require the
variable to be set; to fall back to the parent's defaults instead, delete the
`-m` flag and the variable together rather than leaving it empty.

## Start a session

Keep the target workspace separate from temporary orchestration state. Launch
this block in the orchestrator's background terminal:

```bash
workdir=/absolute/path/to/workspace
model=provider/model-id
run_id="$(uuidgen)"
run_dir="/tmp/opencode-${run_id}"
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Inspect the failing tests, identify the cause, and report a minimal fix plan. Do not edit yet.'

mkdir "$run_dir" || exit 1
printf 'run_dir=%s\n' "$run_dir"

cd "$workdir" || exit 1

printf '%s' "$prompt" |
  opencode run --format json \
    --dangerously-skip-permissions \
    -m "$model" \
    >"$events_file" \
    2>"$stderr_file" &
echo $! > "$run_dir/pid"
wait $!
run_status=$?

session_id="$(jq -r 'select(.sessionID) | .sessionID' "$events_file" | head -1)"
[[ "$session_id" =~ ^ses_[A-Za-z0-9]+$ ]] || { printf 'no session id\n' >&2; exit 1; }
printf 'session_id=%s\n' "$session_id"

final_text="$(jq -rs '
  [.[] | select(.type == "text")] as $t
  | if ($t | length) == 0 then empty
    else ($t | last | .part.messageID) as $m
      | [$t[] | select(.part.messageID == $m) | .part.text] | join("")
    end
' "$events_file")"

if [[ "$run_status" -ne 0 || -z "$final_text" ]]; then
  printf 'turn failed: status=%s\n' "$run_status" >&2
  exit 1
fi

printf '%s\n' "$final_text"
exit "$run_status"
```

Retain `run_id`, `run_dir`, the background terminal identifier, and `session_id`
in the parent agent's task state. Raw JSONL and stderr remain in `run_dir`, one
timestamped set per turn; only the identifiers and final response enter the
parent agent's context.

## Continue the session

Send every correction, question, or next step to the same session:

```bash
workdir=/absolute/path/to/workspace
session_id=RETAINED_SESSION_ID
model=provider/model-id
run_dir=/tmp/opencode-RETAINED_RUN_ID
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Implement the plan, run the focused tests, and report changed files and verification results.'

cd "$workdir" || exit 1

printf '%s' "$prompt" |
  opencode run --format json \
    --session "$session_id" \
    --dangerously-skip-permissions \
    -m "$model" \
    >"$events_file" \
    2>"$stderr_file" &
echo $! > "$run_dir/pid"
wait $!
run_status=$?

final_text="$(jq -rs '
  [.[] | select(.type == "text")] as $t
  | if ($t | length) == 0 then empty
    else ($t | last | .part.messageID) as $m
      | [$t[] | select(.part.messageID == $m) | .part.text] | join("")
    end
' "$events_file")"

if [[ "$run_status" -ne 0 || -z "$final_text" ]]; then
  printf 'turn failed: status=%s\n' "$run_status" >&2
  exit 1
fi

printf '%s\n' "$final_text"
exit "$run_status"
```

Repeat `opencode run --session` until the delegated task is complete.

Pass the model on every resumed turn so separate CLI invocations use the same
settings. Change it deliberately when a later turn needs a different model.

## Monitor a running turn

Poll the background terminal for process status. To inspect progress without
loading raw event bodies into the parent agent's context, run this against the
current `events_file`:

```bash
events_file="$(ls -t /tmp/opencode-RETAINED_RUN_ID/*.events.jsonl | head -n 1)"

jq -Rr '
  fromjson?
  | if .type == "step_start" then
      "step_start"
    elif .type == "step_finish" then
      "step_finish cost=\(.part.cost // "?")"
    elif .type == "tool_use" then
      "tool \(.part.tool) \(.part.state.status)"
    elif .type == "text" then
      "text"
    else
      empty
    end
' "$events_file" | tail -n 20
```

Events flush to stdout in real-time (unbuffered). Interpret them as follows:

| Signal | Meaning |
| --- | --- |
| `step_start` | OpenCode began a new reasoning step. |
| `tool_use` | OpenCode invoked a tool; `.part.tool` names it, `.part.state.status` is `completed` or `running`. |
| `text` | OpenCode produced output or a progress update. |
| `step_finish` | A reasoning step completed; `.part.tokens` and `.part.cost` carry usage. |

A newly received event proves progress. A live process with no new event proves
only liveness: OpenCode may be reasoning, waiting on a model response, or
stalled. OpenCode cannot guarantee periodic events during model inference, so
never declare a stall from silence alone.

Treat process exit without a `step_finish` or `text` event as an interruption
and recover as described in Interrupting and Redirecting.

## Interrupting and Redirecting

A live `opencode run` turn accepts no follow-up input. To interrupt it, use the
orchestrator's native background-terminal facility to send SIGTERM to the
process. OpenCode honors it within seconds.

Each Start and Continue block writes the child's PID to `$run_dir/pid`. Read it
and send SIGTERM; escalate to SIGKILL if the child does not exit within five
seconds:

```bash
run_dir=/tmp/opencode-RETAINED_RUN_DIR
pid="$(cat "$run_dir/pid" 2>/dev/null)" && {
  kill -TERM "$pid" 2>/dev/null
  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"
}
```

Keep `run_dir` for diagnostics when the process exits without a terminal event.

Then send the next turn with `opencode run --session "$session_id"` as usual:

- To recover from an involuntary interruption (timeout, crash, operator stop),
  instruct the child to continue where it left off.
- To redirect, state the new instruction and that the previous one is
  superseded.

Tool calls that completed before the kill have already taken effect — files were
edited, commands ran — so tell the child it was interrupted mid-task and to
reassess the workspace before continuing.

## Rules

- Authenticate once (interactive `opencode auth login` or provider env vars)
  before delegating.
- Always pass `--format json`; without it OpenCode writes formatted text that is
  hard to parse reliably.
- Headless runs cannot answer permission prompts — a tool call that would
  prompt is simply denied. `--dangerously-skip-permissions` removes the gates;
  it also grants the child the invoking user's full privileges, so delegate only
  work the operator would run directly. To keep a host gated instead, omit the
  flag from the blocks above and accept that gated tool calls will be denied,
  completing with degraded capability. Treat a nonzero exit that follows a
  denied tool call as a degraded run, not a failure.
- The tool set is configuration-dependent: core tools (bash, read, write,
  edit, glob, grep, webfetch, websearch) plus whatever skills, plugins, and
  MCP servers the operator has configured. Do not assume an optional tool
  exists on every host.
- Sessions are stored per working directory: run every turn from the same
  `workdir`.
- Use an explicit `--session "$session_id"`; never use `--continue` when agents
  may run concurrently.
- Do not resume the same session concurrently.
- Pass prompts through stdin and quote shell variables. A positional prompt is
  visible in the process list and subject to argument-length limits; stdin
  avoids both. This prevents shell injection; it does not make untrusted
  prompt content safe.
- Treat a nonzero exit, or exit without any `text` event, as failure. Report
  it instead of presenting a partial reply as success. A successful short turn
  may emit no `step_finish`, so do not require one.

## Clean up

Keep `run_dir` while the delegated conversation may receive follow-up turns.
After the parent has received the final response and the delegation is complete,
the parent may remove `run_dir` using its own safe cleanup mechanism.

Retain the directory after a failed turn until its JSONL and stderr have been
inspected. Removing it does not delete the persisted OpenCode conversation under
`~/.local/share/opencode`; it removes only this delegation's per-turn event log
and stderr.
