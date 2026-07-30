# Kimi Code CLI

Use `kimi -p` for the first turn and `kimi -p --session` for every follow-up.
Each turn is one noninteractive process; the persisted session under
`~/.kimi-code/sessions/` carries the conversation across turns.

Prompt mode never asks for approval or questions: regular tool calls run under
the auto permission policy while static deny rules stay in effect. `--prompt`
cannot be combined with `--yolo`, `--auto`, or `--plan` — do not add them.

## Choose the model

Use the configured `default_model` from `~/.kimi-code/config.toml` unless the
operator explicitly requests a particular model alias. The orchestrator must
not choose an override proactively.

**Configured default:** leave `model_args` empty.

```bash
model_args=()
```

**Explicit operator-requested override:** pass the alias with `-m` on every
turn, including resumed ones.

```bash
model=kimi-code/k3
model_args=(-m "$model")
```

## Start a session

Use an explicit absolute workspace and keep temporary orchestration state in a
separate per-delegation directory. Each turn gets distinct events and stderr
files:

```bash
workdir=/absolute/path/to/workspace
model_args=()
# model=kimi-code/k3
# model_args=(-m "$model")
run_id="$(uuidgen)"
run_dir="/tmp/kimi-${run_id}"
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Inspect the failing tests, identify the cause, and report a minimal fix plan. Do not edit yet.'

mkdir "$run_dir" || exit 1
printf 'run_dir=%s\n' "$run_dir"
cd "$workdir" || exit 1

kimi -p "$prompt" \
  "${model_args[@]}" \
  --output-format stream-json \
  >"$events_file" \
  2>"$stderr_file"
run_status=$?

hint="$(jq -c 'select(.type == "session.resume_hint")' "$events_file" | tail -n 1)"
session_id="$(jq -r '.session_id // empty' <<<"$hint")"
if [[ "$run_status" -ne 0 || -z "$session_id" ]]; then
  printf 'turn failed: status=%s session_id=%s\n' "$run_status" "${session_id:-none}" >&2
  exit 1
fi
printf 'session_id=%s\n' "$session_id"

jq -r 'select(.role == "assistant") | .content // empty' "$events_file"
exit "$run_status"
```

In `stream-json` mode each stdout line is a JSON object: assistant messages
(`{"role":"assistant","content":...}`, with `tool_calls` when the model calls
tools), tool result messages, and a terminal
`{"role":"meta","type":"session.resume_hint","session_id":"session_...","command":"kimi -r session_..."}`
event that carries the resumable session ID. Thinking content is not written
to the JSONL; tool progress and "resuming session" notices go to stderr.

Retain `run_id`, `run_dir`, `session_id`, and the host's background task
identifier in parent task state. Keep only identifiers and the final response
in parent context; the per-turn files preserve diagnostics.

## Continue the session

Run follow-ups from the same explicit absolute workspace and resume only the
captured session ID:

```bash
workdir=/absolute/path/to/workspace
session_id=RETAINED_SESSION_ID   # e.g. session_75bc8af6-...
run_dir=/tmp/kimi-RETAINED_RUN_ID
model_args=()
# model=kimi-code/k3
# model_args=(-m "$model")
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Implement the plan, run the focused tests, and report changed files and verification results.'

cd "$workdir" || exit 1

kimi -p "$prompt" \
  --session "$session_id" \
  "${model_args[@]}" \
  --output-format stream-json \
  >"$events_file" \
  2>"$stderr_file"
run_status=$?

resumed="$(jq -r 'select(.type == "session.resume_hint") | .session_id // empty' "$events_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || "$resumed" != "$session_id" ]]; then
  printf 'turn failed or session mismatch: status=%s resumed=%s\n' "$run_status" "${resumed:-none}" >&2
  exit 1
fi

jq -r 'select(.role == "assistant") | .content // empty' "$events_file"
exit "$run_status"
```

Repeat with `--session "$session_id"` until the delegated task is complete. Do
not use `-c`/`--continue` or infer a "most recent" session: concurrent
delegations make recency ambiguous. (`-r` is a hidden alias for `--session`.)

## Monitor a running turn

Poll the host's background task for process liveness. To inspect progress
without loading raw event bodies into the parent agent's context, run this
against the current `events_file`:

```bash
events_file="$(ls -t /tmp/kimi-RETAINED_RUN_ID/*.events.jsonl | head -n 1)"

jq -Rr '
  fromjson?
  | if .role == "assistant" and (.tool_calls | length) > 0 then
      "assistant tool_calls=\([.tool_calls[].name] | join(","))"
    elif .role == "assistant" then
      "assistant text"
    elif .role == "tool" then
      "tool_result"
    elif .type == "session.resume_hint" then
      "done session=\(.session_id)"
    else
      empty
    end
' "$events_file" | tail -n 20
```

A newly appended event proves progress. Nothing is emitted between an
assistant `tool_calls` message and its tool result — a long build or test run
is silent for its whole duration. Treat silence as inconclusive: use the
orchestrator's task status as the liveness signal and bound the turn with a
generous hard deadline rather than inferring a stall from quiet alone.

Treat process exit without a `session.resume_hint` event as an interruption
and recover as described in Interrupting and redirecting.

## Interrupting and redirecting

A live `-p` turn accepts no follow-up input. Stop the child with the
orchestrator's native task-stop facility, confirm it exited, then resume with
`--session "$session_id"` and the next instruction. Completed messages and
tool results are persisted under `~/.kimi-code/sessions/` as the turn runs, so
prior progress survives termination; only the in-flight increment is lost.
Never run two turns against the same child session concurrently.

Resume only if a validated `session.resume_hint` event has already been
captured. If interruption occurs before an ID is available, do not guess from
session recency; start a new explicit child session instead.

For recovery, tell the resumed child that the previous turn was interrupted
and to reassess the workspace. For redirection, state that the new instruction
supersedes the interrupted one. Tool calls completed before termination may
already have changed files or external state.

## Rules

- Always pass `-p`; without it kimi starts an interactive TUI that hangs the
  calling tool.
- Never combine `-p` with `--yolo`, `--auto`, or `--plan`; the combination is
  rejected at startup, and prompt mode already runs under auto permissions.
- Prompt mode grants the child the invoking user's privileges without
  approval prompts; delegate only work the operator authorizes.
- Capture the session ID from the `session.resume_hint` event and validate it
  before retaining; do not scrape `session_index.jsonl` for recency.
- Use an explicit `--session "$session_id"`; never select the latest session.
- Keep one live turn per session and one session per delegated task.
- Quote the `-p "$prompt"` argument. Prompt text remains visible in the
  process list and is subject to command-line length limits, so do not put
  secrets or unbounded content in it.
- Treat a nonzero exit, a missing resume hint, or an empty final response as
  failure. Do not present partial output as success.

## Clean up

Keep `run_dir` while follow-up turns remain possible. After the final response
has been reviewed and the delegation is complete, remove it with the parent's
safe cleanup mechanism.

Retain the directory after failure or interruption until the events and stderr
files have been inspected. Removing `run_dir` deletes only this delegation's
temporary capture files; it does not delete kimi's persisted child session.
