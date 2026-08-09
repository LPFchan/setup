# Muse Code

Use `muse exec` for every turn. Each turn is one noninteractive process; the
persisted session under `~/.local/share/muse/sessions/YYYY/MM/DD/<session-id>/`
carries the conversation across turns.

Unlike the other harnesses, the parent chooses the session id up front and
passes the same `--session-id` on every turn. Nothing has to be scraped out of
the first turn's output to make follow-ups possible, and a turn that dies
before emitting anything still leaves a resumable session.

## Parent control fallback

Muse currently exposes no documented machine-readable live-input RPC for an
active `muse exec` turn. Use managed bash plus a durable per-session broker
queue:

- **OBSERVE (native task/events):** use `/tasks` for process liveness and read
  `task.lifecycle.*`, `run.output.delta`, and `run.terminal.completed` records
  from the current JSONL output. A quiet live task is not proof of progress.
- **STEER (fallback):** there is no live steer operation. Persist guidance for
  the next turn. For an urgent redirect, queue a superseding instruction, stop
  the managed task, confirm exit, then start the next `muse exec` with the
  same `--session-id`. Under the broker lock, mark displaced pending records
  `superseded` before promoting the redirect.
- **QUEUE (broker):** use a transactional private per-session store, not an
  unsynced append-only file. Track `pending`, `in_flight`, `applied`, and
  `unknown` states. Commit `pending -> in_flight` before submission; on
  recovery, transactionally convert any `in_flight` row without terminal
  evidence to `unknown` before draining, and never replay `unknown`
  automatically. For an urgent redirect, one transaction must mark displaced
  pending rows `superseded` and insert/promote the redirect before interrupting
  or acknowledging it. Acknowledge application only after the next turn
  consumes the record. A single serialized controller preserves FIFO order.
- **INTERRUPT (native task facility):** stop the exact managed bash task and
  wait for terminal confirmation before resuming. Do not use shell `kill`,
  `nohup`, or `&` to bypass Muse's task manager.

```bash
umask 077
queue_db="$run_dir/control.queue.sqlite3"
message_id="$(uuidgen)"
python3 - "$queue_db" "$message_id" <<'PY'
import sqlite3
import sys

db, message_id = sys.argv[1:]
conn = sqlite3.connect(db, isolation_level=None)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA synchronous=FULL")
conn.execute("CREATE TABLE IF NOT EXISTS queue (seq INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT UNIQUE NOT NULL, instruction TEXT NOT NULL, state TEXT NOT NULL)")
conn.execute("BEGIN IMMEDIATE")
conn.execute("INSERT INTO queue(message_id, instruction, state) VALUES (?, ?, 'pending')", (message_id, "NEXT INSTRUCTION"))
conn.execute("COMMIT")
conn.close()
PY
# A zero exit is the acknowledgement; recover only complete committed rows.
```

SQLite recovery exposes only committed rows. If an older JSONL queue is being
migrated, quarantine a truncated final line for operator review rather than
silently replaying or discarding it.

Completed tools and side effects survive interruption. Reassess the workspace
before draining the queue.

## Choose the model

Use the configured default unless the operator explicitly requests a
particular model. The orchestrator must not choose an override proactively.

**Configured default:** leave `model_args` empty.

```bash
model_args=()
```

**Explicit operator-requested override:** pass the id with `--model` on every
turn, including resumed ones.

```bash
model_args=(--model muse-spark-1.2)
```

Reasoning effort defaults to `high` and is set with
`--reasoning-effort none|minimal|low|medium|high|xhigh|ultra`. Leave it alone
unless the operator asks.

## Start a session

Approval prompts and the OS sandbox are ON by default, and an unattended
`muse exec` cannot answer an approval prompt. Pass `--yolo` to disable
approval and sandboxing and trust the workspace for the run — this grants the
child the invoking user's privileges, so delegate only work the operator
authorizes. `--user-input-auto-resolve` keeps a child that asks a question
from stalling: the prompt is auto-cancelled instead of waiting forever.

Use an explicit absolute workspace and keep temporary orchestration state in a
separate per-delegation directory. Each turn gets distinct events and stderr
files:

```bash
workdir=/absolute/path/to/workspace
model_args=()
session_id="$(uuidgen)"
run_dir="/tmp/muse-${session_id}"
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Inspect the failing tests, identify the cause, and report a minimal fix plan. Do not edit yet.'

mkdir "$run_dir" || exit 1
printf 'session_id=%s\nrun_dir=%s\n' "$session_id" "$run_dir"
cd "$workdir" || exit 1

muse exec "$prompt" \
  --json \
  --session-id "$session_id" \
  --yolo \
  --user-input-auto-resolve \
  "${model_args[@]}" \
  >"$events_file" \
  2>"$stderr_file"
run_status=$?

terminal="$(jq -c 'select(.payload_type == "run.terminal.completed")' "$events_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || -z "$terminal" ]]; then
  printf 'turn failed: status=%s\n' "$run_status" >&2
  exit 1
fi

jq -r '.payload.text // empty' <<<"$terminal"
exit "$run_status"
```

In `--json` mode each stdout line is one session record. The fields that
matter: `payload_type` names the event, `payload` carries it, and `stream.id`
is the session id. The ones to read are `turn.input.user` (the prompt this
turn), `run.output.delta` (`payload.text`, streamed assistant output),
`run.terminal.completed` (`payload.terminal` is `completed`, and
`payload.text` is the final response), and `task.lifecycle.*` (tool activity).
Everything else is runtime bookkeeping.

Retain `session_id`, `run_dir`, and the host's background task identifier in
parent task state. Keep only identifiers and the final response in parent
context; the per-turn files preserve diagnostics.

## Continue the session

Run follow-ups from the same explicit absolute workspace and pass the same
`--session-id`:

```bash
workdir=/absolute/path/to/workspace
session_id=RETAINED_SESSION_ID
run_dir="/tmp/muse-${session_id}"
model_args=()
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Implement the plan, run the focused tests, and report changed files and verification results.'

cd "$workdir" || exit 1

muse exec "$prompt" \
  --json \
  --session-id "$session_id" \
  --yolo \
  --user-input-auto-resolve \
  "${model_args[@]}" \
  >"$events_file" \
  2>"$stderr_file"
run_status=$?

resumed="$(jq -r 'select(.payload_type == "session.resumed")
                  | .payload.record.prior_turn_count // empty' "$events_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || -z "$resumed" ]]; then
  printf 'turn failed or session did not resume: status=%s resumed=%s\n' \
    "$run_status" "${resumed:-none}" >&2
  exit 1
fi

jq -r 'select(.payload_type == "run.terminal.completed") | .payload.text // empty' \
  "$events_file" | tail -n 1
exit "$run_status"
```

A resumed turn records `session.resumed` with `prior_turn_count` and
`resumed_from_sequence`, and its `session.opened.observed` carries
`resume: true`. A first turn records neither. Use that to confirm the child
picked up the existing conversation rather than silently starting a fresh one
under the same id.

Repeat with the same `--session-id` until the delegated task is complete.
Never derive the id from session recency: concurrent delegations make recency
ambiguous, and the id was chosen by the parent anyway.

## Monitor a running turn

Poll the host's background task for process liveness. To inspect progress
without loading raw event bodies into the parent agent's context, run this
against the current `events_file`:

```bash
events_file="$(ls -t /tmp/muse-RETAINED_SESSION_ID/*.events.jsonl | head -n 1)"

jq -Rr '
  fromjson?
  | if .payload_type == "task.lifecycle.started" then
      "tool started"
    elif .payload_type == "task.lifecycle.completed" then
      "tool completed"
    elif .payload_type == "task.lifecycle.failed" then
      "tool failed"
    elif .payload_type == "run.output.delta" then
      "assistant text"
    elif .payload_type == "run.terminal.completed" then
      "done terminal=\(.payload.terminal)"
    else
      empty
    end
' "$events_file" | tail -n 20
```

A newly appended event proves progress. Nothing is emitted between a tool
start and its completion — a long build or test run is silent for its whole
duration. Treat silence as inconclusive: use the orchestrator's task status as
the liveness signal and bound the turn with a generous hard deadline rather
than inferring a stall from quiet alone.

Treat process exit without a `run.terminal.completed` event as an interruption
and recover as described below.

## Interrupting and redirecting

A live `exec` turn accepts no follow-up input. Stop the child with the
orchestrator's native task-stop facility, confirm it exited, then start the
next turn with the same `--session-id` and the next instruction. Records are
appended to the session log as the turn runs, so prior progress survives
termination; only the in-flight increment is lost.

Because the parent chose the id, an interrupted first turn is still
resumable — there is no "no id captured yet" failure mode. Verify the session
directory exists before resuming; if it does not, the child died before
opening the session and the next turn is a fresh start, not a resume.

For recovery, tell the resumed child that the previous turn was interrupted
and to reassess the workspace. For redirection, state that the new instruction
supersedes the interrupted one. Tool calls completed before termination may
already have changed files or external state.

## Rules

- Always use `muse exec`; bare `muse` starts an interactive TUI that hangs the
  calling tool.
- Always pass `--session-id`; generate it with `uuidgen` before the first turn
  and reuse it verbatim.
- Pass `--yolo` for unattended runs, and only for work the operator
  authorizes. Without it the child can block on an approval prompt it cannot
  answer.
- Add `--user-input-auto-resolve` so a child that asks a question cancels the
  prompt instead of stalling the turn.
- Keep one live turn per session and one session per delegated task; never run
  two turns against the same session concurrently.
- Quote the prompt argument. Prompt text remains visible in the process list
  and is subject to command-line length limits, so do not put secrets or
  unbounded content in it. Use `--prompt-file <PATH>` for long prompts.
- Treat a nonzero exit, a missing `run.terminal.completed` event, or an empty
  final response as failure. Do not present partial output as success.
- `-w`/`--worktree create` runs the child in its own git worktree when the
  delegation must not touch the parent's working copy.

## Clean up

Keep `run_dir` while follow-up turns remain possible. After the final response
has been reviewed and the delegation is complete, remove it with the parent's
safe cleanup mechanism.

Retain the directory after failure or interruption until the events and stderr
files have been inspected. Removing `run_dir` deletes only this delegation's
temporary capture files; it does not delete muse's persisted child session.
