# Hermes Agent

Use `hermes chat -Q -q` for the first turn and add `--resume` with the captured
session ID for every follow-up. Each turn is one noninteractive process; the
persisted session carries the conversation across turns.

Do not use `hermes -z`. Its oneshot path declares a stateless channel and does
not expose or resume the persisted child conversation required by this
workflow.

## Choose the model and provider

Hermes can use its configured default model and provider. To pin routing,
specify model and provider together:

```bash
model_args=()
# To pin routing, uncomment and set both lines:
# provider=openrouter
# model=anthropic/claude-sonnet-4
# model_args=(--provider "$provider" --model "$model")
```

The recipes below work with an empty `model_args` array. If routing is pinned,
pass the same pair on every resumed turn; change it only deliberately. Never
set only one variable while implying that the pair is pinned.

## Start a session

Use an explicit absolute workspace and keep temporary orchestration state in a
separate per-delegation directory. Each turn gets distinct final-output and
stderr files:

```bash
workdir=/absolute/path/to/workspace
model_args=()
# provider=openrouter
# model=anthropic/claude-sonnet-4
# model_args=(--provider "$provider" --model "$model")
run_id="$(uuidgen)"
run_dir="/tmp/hermes-${run_id}"
turn="$(date +%Y%m%dT%H%M%S)"
final_file="$run_dir/${turn}.final.txt"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Inspect the failing tests, identify the cause, and report a minimal fix plan. Do not edit yet.'

mkdir "$run_dir" || exit 1
printf 'run_dir=%s\n' "$run_dir"
cd "$workdir" || exit 1

hermes chat -Q --source tool --accept-hooks --yolo --pass-session-id \
  "${model_args[@]}" \
  -q "$prompt" \
  >"$final_file" \
  2>"$stderr_file"
run_status=$?

mapfile -t session_ids < <(sed -n 's/^session_id: //p' "$stderr_file")
if (( ${#session_ids[@]} != 1 )); then
  printf 'expected one session_id line, found %s\n' "${#session_ids[@]}" >&2
  exit 1
fi
session_id="${session_ids[0]}"
if [[ ! "$session_id" =~ ^[[:alnum:]_.:-]+$ || ${#session_id} -gt 256 ]]; then
  printf 'invalid session id\n' >&2
  exit 1
fi
printf 'session_id=%s\n' "$session_id"

if [[ "$run_status" -ne 0 || ! -s "$final_file" ]]; then
  printf 'turn failed: status=%s\n' "$run_status" >&2
  exit 1
fi

cat "$final_file"
exit "$run_status"
```

`-Q` suppresses banners, spinners, and tool previews. The final child response
is captured from stdout, while the exact `session_id: <id>` line is extracted
from stderr. Requiring one well-formed line prevents an unrelated diagnostic
from being mistaken for the resumable session identifier.

Retain `run_id`, `run_dir`, `session_id`, and the host's background process
session ID in parent task state. Keep only identifiers and the final response
in parent context; the per-turn files preserve diagnostics.

## Continue the session

Run follow-ups from the same explicit absolute workspace and resume only the
captured session ID:

```bash
workdir=/absolute/path/to/workspace
session_id=RETAINED_SESSION_ID
run_dir=/tmp/hermes-RETAINED_RUN_ID
model_args=()
# provider=openrouter
# model=anthropic/claude-sonnet-4
# model_args=(--provider "$provider" --model "$model")
turn="$(date +%Y%m%dT%H%M%S)"
final_file="$run_dir/${turn}.final.txt"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Implement the plan, run the focused tests, and report changed files and verification results.'

cd "$workdir" || exit 1

hermes chat -Q --source tool --accept-hooks --yolo --pass-session-id \
  --resume "$session_id" \
  "${model_args[@]}" \
  -q "$prompt" \
  >"$final_file" \
  2>"$stderr_file"
run_status=$?

mapfile -t resumed_ids < <(sed -n 's/^session_id: //p' "$stderr_file")
if (( ${#resumed_ids[@]} != 1 )) || [[ "${resumed_ids[0]}" != "$session_id" ]]; then
  printf 'missing or mismatched resumed session id\n' >&2
  exit 1
fi

if [[ "$run_status" -ne 0 || ! -s "$final_file" ]]; then
  printf 'turn failed: status=%s\n' "$run_status" >&2
  exit 1
fi

cat "$final_file"
exit "$run_status"
```

Repeat with `--resume "$session_id"` until the delegated task is complete. Do
not use `--continue` or infer a "most recent" session: concurrent delegations
make recency ambiguous.

## Run from a Hermes host

Launch each command block with Hermes's terminal tool using
`background=true` and `notify_on_complete=true`. Keep the returned process
session ID, then use the process tool for lifecycle control:

- `poll` or `log` to inspect status and available output;
- `wait` to await completion;
- `kill` to stop an unneeded or redirected turn.

Do not append `&`, wrap the command in `nohup`, or otherwise detach it in the
shell. Shell-level backgrounding hides the real child lifecycle from Hermes's
native process manager. Native `delegate_task` also does not replace this
recipe when the requirement is an explicitly resumable external child-harness
session.

## Monitor a running turn

Quiet CLI mode provides process liveness during the turn and the final response
at completion. It does **not** provide a structured incremental progress feed.
Poll the host process session to determine whether the command is still live;
inspect the current files for data already flushed, but do not interpret a
quiet or unchanged file as a stall. The child may be reasoning, waiting on a
model response, or running a long tool command.

When structured streaming events are a hard requirement, the Hermes TUI
gateway JSON-RPC interface is an advanced integration alternative. It is not
the default command-line recipe and requires a dedicated protocol client.

## Interrupting and redirecting

A live quiet turn accepts no follow-up input. Use the host's native process
`kill` action, then `poll` or `wait` until exit is confirmed before resuming.
Never run two turns against the same child session concurrently.

Resume only if a validated `session_id:` line has already been captured from
the turn's stderr. If interruption occurs before an ID is available, do not
guess from session recency; start a new explicit child session instead.

For recovery, tell the resumed child that the previous turn was interrupted and
to reassess the workspace. For redirection, state that the new instruction
supersedes the interrupted one. Tool calls completed before termination may
already have changed files or external state.

## Rules

- Authenticate and configure Hermes before unattended delegation.
- Always use `hermes chat -Q -q`; never use `hermes -z` for resumable work.
- Pass `--source tool` so integration sessions stay out of default user session
  listings.
- Pass `--accept-hooks` and `--yolo` so unseen hooks and dangerous-command
  approvals cannot block on an unattended prompt. These flags grant the child
  the invoking user's privileges; delegate only work the operator authorizes.
- Pass `--pass-session-id` and validate the exact stderr line before retaining
  the ID.
- Use an explicit `--resume "$session_id"`; never select the latest session.
- Keep one live turn per session and one session per delegated task.
- Quote the `-q "$prompt"` argument. Prompt text remains visible in the process
  list and is subject to command-line length limits, so do not put secrets or
  unbounded content in it.
- Treat a nonzero exit, a missing or invalid session ID, or an empty final
  response as failure. Do not present partial output as success.

## Clean up

Keep `run_dir` while follow-up turns remain possible. After the final response
has been reviewed and the delegation is complete, remove it with the parent's
safe cleanup mechanism.

Retain the directory after failure or interruption until stderr and final
output have been inspected. Removing `run_dir` deletes only this delegation's
temporary capture files; it does not delete Hermes's persisted child session.