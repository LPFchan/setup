# Grok Build

Use `grok -p` for the first turn and `grok --resume <id> -p` for every
follow-up. Each turn is one noninteractive process; the persisted session
under `~/.grok/sessions/` carries the conversation across turns.

`--always-approve` auto-approves all tool executions so an unattended turn
cannot block on a permission prompt. It grants the child the invoking user's
privileges; delegate only work the operator authorizes.

## Choose the model

Use Grok's configured default model unless the operator explicitly requests a
particular model ID. The orchestrator must not choose an override proactively.

**Configured default:** leave `model_args` empty.

```bash
model_args=()
```

**Explicit operator-requested override:** pass the model ID with `-m` on every
turn, including resumed ones. Reasoning models also accept
`--reasoning-effort <effort>`.

```bash
model=grok-4.5
model_args=(-m "$model")
```

## Start a session

Use an explicit absolute workspace and keep temporary orchestration state in a
separate per-delegation directory. Each turn gets distinct events and stderr
files:

```bash
workdir=/absolute/path/to/workspace
model_args=()
# model=grok-4.5
# model_args=(-m "$model")
run_id="$(uuidgen)"
run_dir="/tmp/grok-${run_id}"
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Inspect the failing tests, identify the cause, and report a minimal fix plan. Do not edit yet.'

mkdir "$run_dir" || exit 1
printf 'run_dir=%s\n' "$run_dir"
cd "$workdir" || exit 1

grok -p "$prompt" \
  "${model_args[@]}" \
  --always-approve \
  --output-format streaming-json \
  >"$events_file" \
  2>"$stderr_file"
run_status=$?

end_event="$(jq -c 'select(.type == "end")' "$events_file" | tail -n 1)"
session_id="$(jq -r '.sessionId // empty' <<<"$end_event")"
if [[ "$run_status" -ne 0 || -z "$session_id" ]]; then
  printf 'turn failed: status=%s session_id=%s\n' "$run_status" "${session_id:-none}" >&2
  exit 1
fi
printf 'session_id=%s\n' "$session_id"

jq -r 'select(.type == "text") | .data' "$events_file"
exit "$run_status"
```

In `streaming-json` mode each stdout line is a JSON object: `thought` deltas
during reasoning, `text` deltas of the assistant reply, and a terminal
`{"type":"end","stopReason":"EndTurn","sessionId":"...","usage":{...}}` event
that carries the resumable session ID and token usage. The default
`--output-format plain` prints only the reply text and exposes no session ID —
always use `streaming-json` for delegation.

Retain `run_id`, `run_dir`, `session_id`, and the host's background task
identifier in parent task state. Keep only identifiers and the final response
in parent context; the per-turn files preserve diagnostics.

## Continue the session

Run follow-ups from the same explicit absolute workspace and resume only the
captured session ID:

```bash
workdir=/absolute/path/to/workspace
session_id=RETAINED_SESSION_ID   # e.g. 019fb303-8cb9-7de3-8bb8-496d09c47a42
run_dir=/tmp/grok-RETAINED_RUN_ID
model_args=()
# model=grok-4.5
# model_args=(-m "$model")
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Implement the plan, run the focused tests, and report changed files and verification results.'

cd "$workdir" || exit 1

grok --resume "$session_id" \
  -p "$prompt" \
  "${model_args[@]}" \
  --always-approve \
  --output-format streaming-json \
  >"$events_file" \
  2>"$stderr_file"
run_status=$?

resumed="$(jq -r 'select(.type == "end") | .sessionId // empty' "$events_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || "$resumed" != "$session_id" ]]; then
  printf 'turn failed or session mismatch: status=%s resumed=%s\n' "$run_status" "${resumed:-none}" >&2
  exit 1
fi

jq -r 'select(.type == "text") | .data' "$events_file"
exit "$run_status"
```

Repeat with `--resume "$session_id"` until the delegated task is complete. Do
not use `-c`/`--continue` or a bare `--resume`: concurrent delegations make
recency ambiguous. Do not pass `--fork-session` unless the parent deliberately
wants a branched copy; the fork gets a new session ID that must be captured
from that turn's `end` event.

## Monitor a running turn

Poll the host's background task for process liveness. To inspect progress
without loading raw event bodies into the parent agent's context, watch the
event stream:

```bash
events_file="$(ls -t /tmp/grok-RETAINED_RUN_ID/*.events.jsonl | head -n 1)"

jq -Rr '
  fromjson?
  | if .type == "thought" then "thought"
    elif .type == "text" then "text"
    elif .type == "end" then "end stopReason=\(.stopReason) turns=\(.num_turns)"
    else .type end
' "$events_file" | uniq -c | tail -n 20
```

A newly appended event proves progress. Long tool executions may emit nothing
for their whole duration. Treat silence as inconclusive: use the
orchestrator's task status as the liveness signal and bound the turn with a
generous hard deadline rather than inferring a stall from quiet alone.

Treat process exit without an `end` event as an interruption and recover as
described in Interrupting and redirecting.

## Interrupting and redirecting

A live `-p` turn accepts no follow-up input. Stop the child with the
orchestrator's native task-stop facility, confirm it exited, then resume with
`--resume "$session_id"` and the next instruction. Never run two turns against
the same child session concurrently.

Resume only if a validated `sessionId` has already been captured from an `end`
event. If interruption occurs before an ID is available, do not guess from
session recency; start a new explicit child session instead.

For recovery, tell the resumed child that the previous turn was interrupted
and to reassess the workspace. For redirection, state that the new instruction
supersedes the interrupted one. Tool calls completed before termination may
already have changed files or external state.

## Rules

- Always pass `-p` (or `--prompt-file`); without it grok starts an interactive
  TUI that hangs the calling tool.
- Always pass `--output-format streaming-json`; the default `plain` format
  exposes no session ID.
- Pass `--always-approve` so approvals cannot block an unattended turn. It
  grants the child the invoking user's full privileges; delegate only work the
  operator authorizes.
- Capture the session ID from the terminal `end` event and validate it before
  retaining.
- Use an explicit `--resume "$session_id"`; never select the latest session.
- Keep one live turn per session and one session per delegated task.
- Quote the `-p "$prompt"` argument. Prompt text remains visible in the
  process list and is subject to command-line length limits, so do not put
  secrets or unbounded content in it. For long prompts use `--prompt-file`.
- Treat a nonzero exit, a missing `end` event, or an empty final response as
  failure. Do not present partial output as success.

## Clean up

Keep `run_dir` while follow-up turns remain possible. After the final response
has been reviewed and the delegation is complete, remove it with the parent's
safe cleanup mechanism.

Retain the directory after failure or interruption until the events and stderr
files have been inspected. Removing `run_dir` deletes only this delegation's
temporary capture files; it does not delete Grok's persisted child session.
