# OpenCodex

OpenCodex (`opencodex`) is not a seventh harness. It is a routing wrapper that
multiplexes a provider, model, and reasoning effort onto one of the harnesses
already covered here — `claude`, `codex`, `grok`, or `kimi` — by launching that
harness against the local OpenCodex proxy.

Delegate through OpenCodex when the child must run on a model the plain harness
cannot reach: a routed provider (`crofai`, `grimoire`, `kimicode`, …) driven by
Codex's or Claude Code's agent loop. The delegation protocol is the leg's, not
OpenCodex's — the thread and session semantics in
[codex.md](codex.md) and [claude-code.md](claude-code.md) apply unchanged.

## Command shape

```
opencodex run <provider> [--model MODEL] [--effort EFFORT] [claude|codex|grok|kimi] [harness arguments...]
```

`--model` and `--effort` are OpenCodex's own flags and **must precede the
harness name**. Everything after the harness name is forwarded to the harness
verbatim — a `--model` placed there configures the harness, not the route.

Effort is translated per leg: `codex` receives
`-c model_reasoning_effort="<effort>"`, `claude` receives a `MAX_THINKING_TOKENS`
budget, and `grok`/`kimi` have no per-request effort control and ignore it.

## Available models

Enumerate the catalogue non-interactively. This is the only supported
discovery path; do not read the proxy's config or catalog files directly.

```bash
opencodex list
```

Output is tab-separated rows under `#` comment lines:

```
# columns: provider	model	efforts	status
# launch: opencodex run <provider> --model <model> [--effort <effort>] [<harness>]
# harnesses: claude, codex, grok, kimi
crofai	crofai/glm-4.7-flash	default	launchable
codex	gpt-5.6-sol	low,medium,high,xhigh,max,ultra	launchable
```

Filter and parse:

```bash
opencodex list --provider crofai | grep -v '^#' | cut -f2
opencodex list --json | jq -r '.providers[] | select(.launchable)
  | .name as $p | .models[] | [$p, .id, (.efforts | join(","))] | @tsv'
```

The `--json` form is a single object with `providers` (each `name`,
`launchable`, and `models` of `id`/`label`/`efforts`/`support`) and
`harnesses`. Pass a row's `model` column straight to `--model`; it is
already in routable form.

Notes on the listing:

- Providers disabled locally never appear. `opencodex list --provider <name>`
  exits nonzero for an unknown or disabled provider and names the enabled set.
- The `efforts` column carries the levels the route actually advertises.
  `default` alone means the model exposes no reasoning control — omit
  `--effort`. `none,default` means reasoning exists but has no named levels.
- Rows with status `unlaunchable` belong to the `other` pseudo-provider, a
  picker-only bucket for models no enabled provider claims. There is no
  `opencodex run other`; ignore those rows.
- `list` starts nothing and prompts for nothing. If the proxy is down it
  narrows to the cached Codex catalog rather than failing, so a listing taken
  while the proxy is stopped may be stale.

## Choose the provider, model, and effort

The parent may pin all three when starting the delegation:

```bash
provider=crofai
model=crofai/glm-4.7-flash
effort=medium
```

Pass a value the listing showed for that provider. To fall back to the route's
own default, delete `--effort` and its variable together rather than leaving the
variable empty.

## Stdout is not clean

`opencodex` runs `ocx ensure` before the harness, which prints proxy and catalog
banners to **stdout**. A redirected JSONL or JSON stream therefore begins with
several non-JSON lines. Every consumer below uses `jq -Rr 'fromjson? | …'`,
which skips unparseable lines, instead of plain `jq -r`. Do not drop the `-R`.

## Delegate through the codex leg

Codex's global flags must appear **before** `exec`. Placing `--sandbox` or
`--ask-for-approval` after `exec` fails with `unexpected argument`.

Launch this block in the orchestrator's background terminal:

```bash
workdir=/absolute/path/to/workspace
provider=crofai
model=crofai/glm-4.7-flash
effort=medium
run_id="$(uuidgen)"
run_dir="/tmp/opencodex-${run_id}"
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
final_file="$run_dir/${turn}.final.txt"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Inspect the failing tests, identify the cause, and report a minimal fix plan. Do not edit yet.'

mkdir "$run_dir" || exit 1
printf 'run_dir=%s\n' "$run_dir"

printf '%s' "$prompt" |
  opencodex run "$provider" --model "$model" --effort "$effort" codex \
    --sandbox workspace-write \
    --ask-for-approval never \
    exec --json \
    --output-last-message "$final_file" \
    --skip-git-repo-check \
    -C "$workdir" \
    - \
    >"$events_file" \
    2>"$stderr_file"
run_status=$?

thread_id="$(jq -Rr 'fromjson? | select(.type == "thread.started") | .thread_id' \
  "$events_file" | head -n 1)"
[[ "$thread_id" =~ ^[0-9a-f-]{36}$ ]] || { printf 'no thread id\n' >&2; exit 1; }
printf 'thread_id=%s\n' "$thread_id"

terminal="$(jq -Rr 'fromjson? | select(.type == "turn.completed" or .type == "turn.failed"
  or .type == "error") | .type' "$events_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || "$terminal" != "turn.completed" ]]; then
  printf 'turn failed: status=%s terminal=%s\n' "$run_status" "${terminal:-none}" >&2
  exit 1
fi

[[ -f "$final_file" ]] && cat "$final_file"
exit "$run_status"
```

Do not pass `-m`/`--model` to Codex here; OpenCodex already supplies the routed
model and the catalog override that makes it resolvable.

Retain `run_id`, `run_dir`, the background terminal identifier, `thread_id`, and
the `provider`/`model`/`effort` triple in the parent agent's task state.

### Continue the codex thread

Resume with the same route on every turn:

```bash
run_dir=/tmp/opencodex-RETAINED_RUN_ID
thread_id=RETAINED_THREAD_ID
provider=crofai
model=crofai/glm-4.7-flash
effort=medium
turn="$(date +%Y%m%dT%H%M%S)"
events_file="$run_dir/${turn}.events.jsonl"
final_file="$run_dir/${turn}.final.txt"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Implement the plan, run the focused tests, and report changed files and verification results.'

printf '%s' "$prompt" |
  opencodex run "$provider" --model "$model" --effort "$effort" codex \
    --sandbox workspace-write \
    --ask-for-approval never \
    exec resume --json \
    --output-last-message "$final_file" \
    --skip-git-repo-check \
    "$thread_id" \
    - \
    >"$events_file" \
    2>"$stderr_file"
run_status=$?

terminal="$(jq -Rr 'fromjson? | select(.type == "turn.completed" or .type == "turn.failed"
  or .type == "error") | .type' "$events_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || "$terminal" != "turn.completed" ]]; then
  printf 'turn failed: status=%s terminal=%s\n' "$run_status" "${terminal:-none}" >&2
  exit 1
fi

[[ -f "$final_file" ]] && cat "$final_file"
exit "$run_status"
```

Repeat until the delegated task is complete. Changing `--model` between turns of
one thread changes the model mid-conversation; do it deliberately, not by
accident.

## Delegate through the claude leg

OpenCodex launches Claude Code through the proxy and rewrites its arguments:

- `--dangerously-skip-permissions` is appended unless you already passed it.
- A `--session-id` is minted when you pass neither a session selector nor an
  explicit id. **Always pass your own `--session-id`**, or the id you need for
  the follow-up turn exists only inside the child's output.
- `--model` is set to the routed model, so do not pass a `--model` of your own
  after the harness name.

```bash
workdir=/absolute/path/to/workspace
provider=crofai
model=crofai/glm-4.7-flash
effort=medium
session_id="$(uuidgen)"
run_dir="/tmp/opencodex-${session_id}"
turn="$(date +%Y%m%dT%H%M%S)"
out_file="$run_dir/${turn}.out.json"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Inspect the failing tests, identify the cause, and report a minimal fix plan. Do not edit yet.'

mkdir "$run_dir" || exit 1
printf 'session_id=%s\nrun_dir=%s\n' "$session_id" "$run_dir"

cd "$workdir" || exit 1

printf '%s' "$prompt" |
  opencodex run "$provider" --model "$model" --effort "$effort" claude \
    -p \
    --session-id "$session_id" \
    --output-format json \
    >"$out_file" \
    2>"$stderr_file"
run_status=$?

result="$(jq -Rc 'fromjson? | select(.type == "result" or has("is_error"))' \
  "$out_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || -z "$result" || "$(jq -r '.is_error' <<<"$result")" != "false" ]]; then
  printf 'turn failed: status=%s\n' "$run_status" >&2
  exit 1
fi
jq -r '.result' <<<"$result"
exit "$run_status"
```

### Continue the claude session

```bash
workdir=/absolute/path/to/workspace
session_id=RETAINED_SESSION_ID
provider=crofai
model=crofai/glm-4.7-flash
effort=medium
run_dir="/tmp/opencodex-${session_id}"
turn="$(date +%Y%m%dT%H%M%S)"
out_file="$run_dir/${turn}.out.json"
stderr_file="$run_dir/${turn}.stderr.log"
prompt='Implement the plan, run the focused tests, and report changed files and verification results.'

cd "$workdir" || exit 1

printf '%s' "$prompt" |
  opencodex run "$provider" --model "$model" --effort "$effort" claude \
    -p \
    --resume "$session_id" \
    --output-format json \
    >"$out_file" \
    2>"$stderr_file"
run_status=$?

result="$(jq -Rc 'fromjson? | select(.type == "result" or has("is_error"))' \
  "$out_file" | tail -n 1)"
if [[ "$run_status" -ne 0 || -z "$result" || "$(jq -r '.is_error' <<<"$result")" != "false" ]]; then
  printf 'turn failed: status=%s\n' "$run_status" >&2
  exit 1
fi
jq -r '.result' <<<"$result"
exit "$run_status"
```

For a live progress feed instead of one final object, substitute
`--output-format stream-json --include-partial-messages --verbose` and read the
events with `jq -Rr 'fromjson? | …'` exactly as [claude-code.md](claude-code.md)
describes; the banner lines are the only difference.

## Monitor a running turn

Poll the background terminal for process status, and the current events file for
progress. On the codex leg:

```bash
events_file="$(ls -t /tmp/opencodex-RETAINED_RUN_ID/*.events.jsonl | head -n 1)"

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

Event semantics are the leg's: see the signal tables in [codex.md](codex.md) and
[claude-code.md](claude-code.md).

A newly received event proves progress. A live process with no new event proves
only liveness — the child may be reasoning, waiting on the provider, blocked in
a tool, or stalled. Routed providers add a hop, so silence is weaker evidence of
trouble here than on a direct harness; never declare a stall from silence alone.
Apply a generous hard deadline when runtime must be bounded, and never resume a
thread or session while its current turn is still live.

Treat process exit without a terminal event as an interruption.

## Interrupting and redirecting

A live turn accepts no follow-up input. Interrupt it by sending SIGINT to the
background task's foreground process through the orchestrator's native facility;
the signal reaches the harness, which shuts the turn down. Confirm the process
tree exited before resuming. If graceful interruption does not finish, force-stop
the task and verify the tree is gone.

Then send the next turn as usual — `exec resume "$thread_id"` on the codex leg,
`--resume "$session_id"` on the claude leg:

- To recover from an involuntary interruption, instruct the child to continue
  where it left off.
- To redirect, state the new instruction and that the previous one is superseded.

Commands and file changes made before the interruption have already taken
effect. Tell the child it was interrupted mid-task and to reassess the workspace
before continuing.

## Known limitation: provider `anthropic` on the claude leg

`opencodex run anthropic … claude` fails with `api_error_status: 404` even when
`anthropic/claude-*` models are live in the catalogue and the OAuth account is
healthy. Routed providers such as `crofai` are unaffected.

Do not route Anthropic models through OpenCodex's claude leg. Delegate to plain
`claude` per [claude-code.md](claude-code.md) instead — that is the same model on
a working path. Anthropic models on the codex leg are a separate question; verify
with a trivial prompt before committing a real task to them.

## Rules

- Discover models with `opencodex list`; never hardcode a model id or read the
  proxy's internal config and catalog files.
- Keep `--model`/`--effort` before the harness name, and Codex's global flags
  before `exec`.
- Parse every stream with `jq -Rr 'fromjson? | …'`; `ocx ensure` banners on
  stdout break plain `jq`.
- Pass an explicit `--session-id` on the claude leg and an explicit `thread_id`
  on the codex leg. Never use `resume --last` or `--continue`.
- Do not resume the same thread or session concurrently.
- Use `workspace-write` by default on the codex leg; reduce it to `read-only`
  when the task needs no edits. Do not use `danger-full-access`. Note that the
  claude leg always runs with permissions skipped, so scope its task
  accordingly.
- Pass prompts through stdin and quote shell variables. This prevents shell
  injection; it does not make untrusted prompt content safe.
- Treat a nonzero exit, a `turn.failed`/`error` event, or `is_error: true` as an
  unsuccessful turn. Never present a partial response as success.
- Keep one child session per delegated task, and keep the provider/model/effort
  triple stable across its turns unless changing it is the point.

## Clean up

Keep `run_dir` while the delegated conversation may receive follow-up turns.
After the parent has the final response and the delegation is complete, remove it
with the orchestrator's own safe cleanup mechanism. Retain it after a failed turn
until its JSONL and stderr have been inspected.

Removing `run_dir` deletes only this delegation's temporary telemetry; the
persisted child conversation lives under the leg's own store (`~/.codex/sessions`
or `~/.claude/projects`) and is untouched.
