# Antigravity CLI child

Use `agy --print` for the first turn and `agy --conversation` for every
follow-up. Run every turn from the same explicit absolute workspace.

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
