# Antigravity CLI child

Use `agy --print` for the first turn and `agy --conversation` for every
follow-up. Run every turn from the same explicit absolute workspace.

## Parent control fallback

Antigravity currently exposes no documented machine-readable live-input RPC.
Use its native background task plus a durable per-conversation broker queue:

- **OBSERVE (native task/logs):** inspect the task manager for process
  liveness and tail the current stdout, stderr, and `--log-file` outputs for
  progress. Unchanged files prove neither progress nor a stall.
- **STEER (fallback):** there is no live steer operation. Persist ordinary
  guidance for the next turn. For an urgent redirect, queue the superseding
  instruction, stop the live task, confirm exit, then resume with
  `--conversation "$conversation_id"`. Under the broker lock, mark displaced
  pending records `superseded` before promoting the redirect.
- **QUEUE (broker):** use a transactional private per-session store, not an
  unsynced append-only file. Track `pending`, `in_flight`, `applied`, and
  `unknown` states. Commit `pending -> in_flight` before submission; on
  recovery, transactionally convert any `in_flight` row without terminal
  evidence to `unknown` before draining, and never replay `unknown`
  automatically. For an urgent redirect, one transaction must mark displaced
  pending rows `superseded` and insert/promote the redirect before interrupting
  or acknowledging it. Mark a record `applied` only after the resumed turn
  consumes it. A single logical controller serializes writes and preserves FIFO
  order.
- **INTERRUPT (native task facility):** stop the exact persistent background
  task through Antigravity's task manager and wait for its terminal state.
  Process-stop acceptance is not terminal confirmation.

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

Completed commands or edits remain in effect after interruption. Reassess the
workspace before draining the next queued instruction.

## Choose the model and effort

Probe the installed catalog before launching:

```bash
agy models
```

Pass `--model` and `--effort` on the first and resumed turns when the operator
requested them. Otherwise allow the user's Antigravity defaults to apply.

## Start the child

Create a private run directory for logs, then start the first turn in the
orchestrator's native background facility:

```bash
run_id=$(date +%s)-$$
run_dir="/tmp/agy-${run_id}"
mkdir -m 700 "$run_dir"
events_file="$run_dir/turn-1.out"
stderr_file="$run_dir/turn-1.err"
log_file="$run_dir/turn-1.log"
workspace=/absolute/path/to/workspace

cd "$workspace" || exit 1
agy --dangerously-skip-permissions \
  --log-file "$log_file" \
  --print "DELEGATED TASK AND CONTEXT" \
  >"$events_file" 2>"$stderr_file"
```

Do not add `--sandbox` unless the operator asks for it. Keep the background
task handle and poll it until the process reaches a terminal state. Read both
output files before deciding whether the turn succeeded.

## Capture the conversation ID

Antigravity does not emit the conversation ID in print-mode stdout. After the
first turn exits, recover the UUID from the per-run log. Fall back to the
documented workspace cache only when the log has no ID:

```bash
conversation_id=$(
  sed -n 's/.*Print mode: conversation=\([0-9A-Fa-f-][0-9A-Fa-f-]*\).*/\1/p' \
    "$log_file" | tail -1
)

if [[ -z "$conversation_id" ]]; then
  conversation_id=$(
    python3 - "$workspace" "$HOME/.gemini/antigravity-cli/cache/last_conversations.json" <<'PY'
import json, os, sys
workspace, path = os.path.realpath(sys.argv[1]), sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    data = {}
print(data.get(workspace, ""))
PY
  )
fi

[[ "$conversation_id" =~ ^[0-9A-Fa-f-]+$ ]] || {
  printf 'could not capture Antigravity conversation id\n' >&2
  exit 1
}
```

The cache is keyed by workspace, so do not start multiple uncaptured first
turns concurrently in the same workspace. A per-run log avoids that ambiguity;
the cache is recovery only.

## Send follow-up turns

Use the captured UUID explicitly and keep the workspace, model, effort,
permissions, and log isolation stable:

```bash
events_file="$run_dir/turn-2.out"
stderr_file="$run_dir/turn-2.err"
log_file="$run_dir/turn-2.log"

cd "$workspace" || exit 1
agy --dangerously-skip-permissions \
  --log-file "$log_file" \
  --conversation "$conversation_id" \
  --print "FOLLOW-UP INSTRUCTION" \
  >"$events_file" 2>"$stderr_file"
```

Run the follow-up through the orchestrator's native background facility and
wait for the previous turn to exit before resuming. Repeat with
`--conversation "$conversation_id"` until the delegated task is complete.

## Verify completion

Treat exit status zero plus a non-empty stdout response as the basic success
signal. Also inspect stderr and the per-turn log for authentication,
permission, timeout, or conversation-loading errors. Verify claimed file
changes and test results independently in the parent workspace.

## Safety rules

- Use an explicit absolute workspace for every turn.
- Capture and resume an explicit conversation UUID; never use `-c` for a
  retained child because another Antigravity session can change the latest
  workspace conversation.
- Never resume the same conversation concurrently.
- Keep `--dangerously-skip-permissions` visible in the launch command so the
  delegated autonomy is intentional.
- Remove only the run directory created for this delegation. Never delete
  Antigravity's conversation store under `~/.gemini/antigravity-cli`.
