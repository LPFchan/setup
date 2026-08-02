#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export TEST_TMP
FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$HOME/.codex/sessions" "$FAKE_BIN"

cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
touch "$TEST_TMP/fzf-started"
cat > "$TEST_TMP/fzf-input"
exit 1
EOF
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
touch "$TEST_TMP/unexpected-dispatch"
EOF
cat > "$FAKE_BIN/find" <<'EOF'
#!/usr/bin/env bash
for _ in {1..100}; do
    [[ -e "$TEST_TMP/fzf-started" ]] && break
    sleep 0.02
done
[[ -e "$TEST_TMP/fzf-started" ]] || printf 'fzf did not start before scan emitted data\n' > "$TEST_TMP/async-failure"
exec /usr/bin/find "$@"
EOF
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/codex" "$FAKE_BIN/find"
PATH="$FAKE_BIN:$PATH"
export PATH

session="$HOME/.codex/sessions/rollout-2024-07-03T18-46-40-test-session.jsonl"
cat > "$session" <<'EOF'
{"type":"session_meta","payload":{"source":"cli","thread_source":"","cwd":"/tmp/project"}}
{"type":"response_item","role":"user","payload":{"content":[{"type":"input_text","text":"Fix timestamp display"}]}}
EOF
touch -t 202407031846.40 "$session"

programmatic_session="$HOME/.codex/sessions/rollout-2024-07-03T18-47-40-programmatic-session.jsonl"
cat > "$programmatic_session" <<'EOF'
{"type":"session_meta","payload":{"source":"exec","thread_source":"","cwd":"/tmp/project"}}
{"type":"response_item","role":"user","payload":{"content":[{"type":"input_text","text":"Programmatic Codex run"}}]}}
EOF
touch -t 202407031847.40 "$programmatic_session"

if "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/stderr"; then
    echo "FAIL: picker failure should fail resume" >&2
    exit 1
fi

grep -Fq 'resume: picker failed with status 1' "$TEST_TMP/stderr" \
    || { echo "FAIL: picker failure was not diagnosed" >&2; exit 1; }
[[ ! -e "$TEST_TMP/unexpected-dispatch" ]] \
    || { echo "FAIL: picker failure dispatched a harness" >&2; exit 1; }

[[ -s "$TEST_TMP/fzf-input" ]] \
    || { echo "FAIL: resume did not send rows to fzf" >&2; exit 1; }
[[ ! -e "$TEST_TMP/async-failure" ]] \
    || { echo "FAIL: $(cat "$TEST_TMP/async-failure")" >&2; exit 1; }
[[ -e "$TEST_TMP/fzf-started" ]] \
    || { echo "FAIL: fzf did not start" >&2; exit 1; }

row=$(cat "$TEST_TMP/fzf-input")
[[ "$row" == 07/03\ 18:46* ]] \
    || { echo "FAIL: resume timestamp was not formatted from epoch: $row" >&2; exit 1; }
[[ "$row" != *"??/?? ??:??"* ]] \
    || { echo "FAIL: resume used fallback timestamp: $row" >&2; exit 1; }
[[ "$row" == *"codex"* && "$row" == *"Fix timestamp display"* ]] \
    || { echo "FAIL: resume row did not include expected session metadata: $row" >&2; exit 1; }
[[ "$row" != *"Programmatic Codex run"* ]] \
    || { echo "FAIL: resume included a programmatic Codex exec session" >&2; exit 1; }

cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 130
EOF
chmod +x "$FAKE_BIN/fzf"
rm -f "$TEST_TMP/stderr" "$TEST_TMP/unexpected-dispatch"

if ! "$ROOT/files/resume" >"$TEST_TMP/stdout" 2>"$TEST_TMP/stderr"; then
    echo "FAIL: picker cancellation should exit successfully" >&2
    exit 1
fi
[[ ! -s "$TEST_TMP/stdout" ]] \
    || { echo "FAIL: picker cancellation wrote to stdout" >&2; exit 1; }
[[ ! -s "$TEST_TMP/stderr" ]] \
    || { echo "FAIL: picker cancellation wrote to stderr" >&2; exit 1; }
[[ ! -e "$TEST_TMP/unexpected-dispatch" ]] \
    || { echo "FAIL: picker cancellation dispatched a harness" >&2; exit 1; }

cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 0
EOF
chmod +x "$FAKE_BIN/fzf"
rm -f "$TEST_TMP/stderr" "$TEST_TMP/unexpected-dispatch"

if "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/stderr"; then
    echo "FAIL: empty picker selection should fail resume" >&2
    exit 1
fi
grep -Fq 'resume: picker returned no selection' "$TEST_TMP/stderr" \
    || { echo "FAIL: empty picker selection was not diagnosed" >&2; exit 1; }
[[ ! -e "$TEST_TMP/unexpected-dispatch" ]] \
    || { echo "FAIL: empty picker selection dispatched a harness" >&2; exit 1; }

cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
selection=$(cat)
printf '%s\n' "$selection"
EOF
cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_TMP/tmux-args"
exit 1
EOF
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0" "$@" > "$TEST_TMP/harness-args"
EOF
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/tmux" "$FAKE_BIN/codex"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/resume-stderr"

expected_tmux_args=$'rename-window\n--\ncodex'
actual_tmux_args=$(cat "$TEST_TMP/tmux-args")
[[ "$actual_tmux_args" == "$expected_tmux_args" ]] \
    || { echo "FAIL: resume sent unexpected tmux arguments: $actual_tmux_args" >&2; exit 1; }

expected_harness_args=$(printf '%s\nresume\ntest-session' "$FAKE_BIN/codex")
actual_harness_args=$(cat "$TEST_TMP/harness-args")
[[ "$actual_harness_args" == "$expected_harness_args" ]] \
    || { echo "FAIL: resume did not dispatch the harness after tmux title failure: $actual_harness_args" >&2; exit 1; }

# Antigravity CLI publishes transcripts below brain/<conversation-id> and a
# workspace-keyed latest-conversation cache. The picker should show that row,
# enter its workspace, and resume it with `agy --conversation <id>`.
agid="bbbbbbbb-1111-4222-8333-cccccccccccc"
agcwd="$HOME/agy-proj"
aglog="$HOME/.gemini/antigravity-cli/brain/$agid/.system_generated/logs"
mkdir -p "$agcwd" "$aglog" "$HOME/.gemini/antigravity-cli/cache"
cat > "$aglog/transcript.jsonl" <<'EOF'
{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\nResume Antigravity work\n</USER_REQUEST>\n<ADDITIONAL_METADATA>ignored</ADDITIONAL_METADATA>"}
{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"ok"}
EOF
printf '{"%s":"%s"}\n' "$agcwd" "$agid" \
    > "$HOME/.gemini/antigravity-cli/cache/last_conversations.json"
touch -t 202407031900.00 "$aglog/transcript.jsonl"

cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
selection=$(cat)
printf '%s\n' "$selection" | grep 'ag|' | head -1
EOF
cat > "$FAKE_BIN/agy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$PWD" "$0" "$@" > "$TEST_TMP/agy-args"
EOF
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/agy"
rm -f "$TEST_TMP/tmux-args"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/agy-stderr"

expected_tmux_args=$'rename-window\n--\nagy'
actual_tmux_args=$(cat "$TEST_TMP/tmux-args")
[[ "$actual_tmux_args" == "$expected_tmux_args" ]] \
    || { echo "FAIL: resume did not set the Antigravity tmux title: $actual_tmux_args" >&2; exit 1; }

expected_agy_args=$(printf '%s\n%s\n--conversation\n%s' "$agcwd" "$FAKE_BIN/agy" "$agid")
actual_agy_args=$(cat "$TEST_TMP/agy-args")
[[ "$actual_agy_args" == "$expected_agy_args" ]] \
    || { echo "FAIL: resume did not dispatch Antigravity: $actual_agy_args" >&2; exit 1; }

# A claude session launched through claudex lands under ~/.claude/projects like
# any native claude session, distinguished only by assistant turns recording
# model "claudex-proxy". resume must tag it clx and relaunch it via
# `claudex run codex --resume <id>` (the launcher supplies core arguments), not bare
# claude (which would resume it on the Anthropic subscription).
cxid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
cxcwd="$HOME/claudex-proj"
mkdir -p "$cxcwd" "$HOME/.claude/projects/-home-claudex-proj"
cxsession="$HOME/.claude/projects/-home-claudex-proj/$cxid.jsonl"
{
    printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"Resume claudex work"}}\n' "$cxcwd"
    printf '{"type":"assistant","message":{"role":"assistant","model":"claudex-proxy","content":[{"type":"text","text":"ok"}]}}\n'
} > "$cxsession"
touch -t 202407041200.00 "$cxsession"

# fzf stub that selects exactly the claudex row (its hidden ref carries "clx|").
# It drains all input first (a partial read would SIGPIPE resume's collection
# pipeline under `set -o pipefail`), then emits the matching row.
cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
selection=$(cat)
printf '%s\n' "$selection" | grep 'clx|' | head -1
EOF
cat > "$FAKE_BIN/claudex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0" "$@" > "$TEST_TMP/claudex-args"
EOF
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/claudex"
rm -f "$TEST_TMP/tmux-args" "$TEST_TMP/harness-args"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/claudex-stderr"

expected_tmux_args=$'rename-window\n--\nclaudex'
actual_tmux_args=$(cat "$TEST_TMP/tmux-args")
[[ "$actual_tmux_args" == "$expected_tmux_args" ]] \
    || { echo "FAIL: resume did not set the claudex tmux title: $actual_tmux_args" >&2; exit 1; }

expected_claudex_args=$(printf '%s\nrun\ncodex\n--resume\n%s' "$FAKE_BIN/claudex" "$cxid")
actual_claudex_args=$(cat "$TEST_TMP/claudex-args")
[[ "$actual_claudex_args" == "$expected_claudex_args" ]] \
    || { echo "FAIL: resume did not dispatch claudex for a claudex-proxy session: $actual_claudex_args" >&2; exit 1; }

# A claudex-proxy session mapped to an arbitrary profile must resume via that
# profile. The launcher writes the mapping and resume reads it.
ccid="aaaaaaaa-bbbb-cccc-dddd-ffffffffffff"
cccwd="$HOME/cc-proj"
mkdir -p "$cccwd" "$HOME/.claude/projects/-home-cc-proj"
ccsession="$HOME/.claude/projects/-home-cc-proj/$ccid.jsonl"
{
    printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"Command code session"}}\n' "$cccwd"
    printf '{"type":"assistant","message":{"role":"assistant","model":"claudex-proxy","content":[{"type":"text","text":"ok"}]}}\n'
} > "$ccsession"
touch -t 202407051200.00 "$ccsession"

# Write the sidecar mapping so resume knows the selected arbitrary profile.
mkdir -p "$HOME/.config/claudex"
printf '%s\t%s\n' "$ccid" "arbitrary-provider" > "$HOME/.config/claudex/sessions.tsv"

# Every new Claudex session uses the single clx tag.
cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
selection=$(cat)
printf '%s\n' "$selection" | grep 'clx|' | grep 'aaaaaaaa-bbbb-cccc-dddd-ffffffffffff' | head -1
EOF
chmod +x "$FAKE_BIN/fzf"
rm -f "$TEST_TMP/tmux-args" "$TEST_TMP/claudex-args"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/claudex-profile-stderr"

expected_cc_args=$(printf '%s\nrun\narbitrary-provider\n--resume\n%s' "$FAKE_BIN/claudex" "$ccid")
actual_cc_args=$(cat "$TEST_TMP/claudex-args")
[[ "$actual_cc_args" == "$expected_cc_args" ]] \
    || { echo "FAIL: resume did not dispatch claudex with the mapped profile: $actual_cc_args" >&2; exit 1; }

# Old picker records using the clxcc tag remain resumable during migration.
cat > "$FAKE_BIN/fzf" <<EOF
#!/usr/bin/env bash
cat >/dev/null
printf 'legacy\tclxcc|$ccid|$cccwd\n'
EOF
chmod +x "$FAKE_BIN/fzf"
rm -f "$TEST_TMP/claudex-args"
TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/claudex-legacy-stderr"
expected_legacy_args=$(printf '%s\nrun\ncommandcode\n--config\n%s/.config/claudex/config.toml\n--dangerously-skip-permissions\n--resume\n%s' \
    "$FAKE_BIN/claudex" "$HOME" "$ccid")
[[ $(cat "$TEST_TMP/claudex-args") == "$expected_legacy_args" ]] \
    || { echo "FAIL: resume dropped legacy clxcc compatibility" >&2; exit 1; }

# OpenCodex-routed Claude sessions have no Claudex model marker. Its launcher
# records the routing provider in a separate sidecar so resume can route the
# transcript back through OpenCodex without changing Claudex compatibility.
ocxid="aaaaaaaa-bbbb-cccc-dddd-111111111111"
ocxcwd="$HOME/opencodex-proj"
mkdir -p "$ocxcwd" "$HOME/.claude/projects/-home-opencodex-proj" "$HOME/.config/opencodex"
ocxsession="$HOME/.claude/projects/-home-opencodex-proj/$ocxid.jsonl"
{
    printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"OpenCodex session"}}\n' "$ocxcwd"
    printf '{"type":"assistant","message":{"role":"assistant","model":"routed-model","content":[{"type":"text","text":"ok"}]}}\n'
} > "$ocxsession"
printf '%s\t%s\n' "$ocxid" "commandcode" > "$HOME/.config/opencodex/sessions.tsv"
touch -t 202407061200.00 "$ocxsession"

cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
selection=$(cat)
[[ "$selection" != *"opencodex:"* ]] || exit 2
printf '%s\n' "$selection" | grep 'ocx|' | head -1
EOF
cat > "$FAKE_BIN/opencodex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0" "$@" > "$TEST_TMP/opencodex-args"
EOF
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/opencodex"
rm -f "$TEST_TMP/tmux-args"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/opencodex-stderr"

expected_opencodex_args=$(printf '%s\nrun\ncommandcode\nclaude\n--resume\n%s' "$FAKE_BIN/opencodex" "$ocxid")
[[ $(cat "$TEST_TMP/opencodex-args") == "$expected_opencodex_args" ]] \
    || { echo "FAIL: resume did not dispatch the mapped OpenCodex session" >&2; exit 1; }
[[ $(cat "$TEST_TMP/tmux-args") == $'rename-window\n--\nopencodex' ]] \
    || { echo "FAIL: resume did not set the OpenCodex tmux title" >&2; exit 1; }

# The sidecar speaks provider, not profile: a session recorded under a bare
# provider name (e.g. a picker-launched codex session) must route through
# that provider verbatim.
ocxpid="aaaaaaaa-bbbb-cccc-dddd-222222222222"
ocxpcwd="$HOME/opencodex-codex-proj"
mkdir -p "$ocxpcwd" "$HOME/.claude/projects/-home-opencodex-codex-proj"
ocxpsession="$HOME/.claude/projects/-home-opencodex-codex-proj/$ocxpid.jsonl"
{
    printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"Picker codex session"}}\n' "$ocxpcwd"
    printf '{"type":"assistant","message":{"role":"assistant","model":"gpt-5.6-sol","content":[{"type":"text","text":"ok"}]}}\n'
} > "$ocxpsession"
printf '%s\t%s\n' "$ocxpid" "codex" >> "$HOME/.config/opencodex/sessions.tsv"
touch -t 202407061300.00 "$ocxpsession"

cat > "$FAKE_BIN/fzf" <<EOF
#!/usr/bin/env bash
selection=\$(cat)
printf '%s\n' "\$selection" | grep 'ocx|' | grep '$ocxpid' | head -1
EOF
chmod +x "$FAKE_BIN/fzf"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/opencodex-provider-stderr"

expected_ocxp_args=$(printf '%s\nrun\ncodex\nclaude\n--resume\n%s' "$FAKE_BIN/opencodex" "$ocxpid")
[[ $(cat "$TEST_TMP/opencodex-args") == "$expected_ocxp_args" ]] \
    || { echo "FAIL: resume did not dispatch a provider-named OpenCodex session through its provider" >&2; exit 1; }

# A uniquely matching non-Claude provider default recovers an active session
# whose sidecar row is not yet durable.
ocxactiveid="aaaaaaaa-bbbb-cccc-dddd-333333333333"
ocxactivecwd="$HOME/opencodex-active-proj"
mkdir -p "$ocxactivecwd" "$HOME/.claude/projects/-home-opencodex-active-proj"
ocxactivesession="$HOME/.claude/projects/-home-opencodex-active-proj/$ocxactiveid.jsonl"
{
    printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"Active OpenCodex session"}}\n' "$ocxactivecwd"
    printf '{"type":"assistant","message":{"role":"assistant","model":"gpt-5.6-sol","content":[{"type":"text","text":"ok"}]}}\n'
} > "$ocxactivesession"
printf '{"providers":{"codex":{"default_model":"gpt-5.6-sol"},"other":{"default_model":"other-model"}}}\n' \
    > "$HOME/.config/opencodex/managed-profiles.json"
touch -t 202407061400.00 "$ocxactivesession"

cat > "$FAKE_BIN/fzf" <<EOF
#!/usr/bin/env bash
selection=\$(cat)
printf '%s\n' "\$selection" | grep 'ocx|' | grep '$ocxactiveid' | head -1
EOF
chmod +x "$FAKE_BIN/fzf"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/opencodex-active-stderr"

expected_ocxactive_args=$(printf '%s\nrun\ncodex\nclaude\n--resume\n%s' "$FAKE_BIN/opencodex" "$ocxactiveid")
[[ $(cat "$TEST_TMP/opencodex-args") == "$expected_ocxactive_args" ]] \
    || { echo "FAIL: resume did not recover an active unmapped OpenCodex session" >&2; exit 1; }

# Hermes persists sessions in ~/.hermes/state.db. Only top-level interactive
# CLI sessions belong in the human resume picker; tool and child sessions must
# stay out of it.
mkdir -p "$HOME/.hermes" "$HOME/hermes-proj"
python3 - "$HOME/.hermes/state.db" "$HOME/hermes-proj" <<'PYEOF'
import sqlite3, sys

db, cwd = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
conn.executescript("""
CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    parent_session_id TEXT,
    cwd TEXT,
    title TEXT,
    started_at REAL NOT NULL,
    ended_at REAL,
    archived INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE messages (
    id INTEGER PRIMARY KEY,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT,
    timestamp REAL NOT NULL
);
""")
conn.execute(
    "INSERT INTO sessions VALUES (?, 'cli', NULL, ?, ?, ?, NULL, 0)",
    ("20240706_120000_hermes", cwd, "Resume Hermes work", 1720267200),
)
conn.execute(
    "INSERT INTO messages(session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)",
    ("20240706_120000_hermes", "First Hermes prompt", 1720267200),
)
conn.execute(
    "INSERT INTO sessions VALUES (?, 'tool', NULL, NULL, ?, ?, NULL, 0)",
    ("20240706_130000_tool", "Hidden tool session", 1720270800),
)
conn.execute(
    "INSERT INTO messages(session_id, role, content, timestamp) VALUES (?, 'user', ?, ?)",
    ("20240706_130000_tool", "Hidden", 1720270800),
)
conn.commit()
conn.close()
PYEOF

cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
selection=$(cat)
[[ "$selection" != *"Hidden tool session"* ]] || exit 2
printf '%s\n' "$selection" | grep 'hm|' | head -1
EOF
cat > "$FAKE_BIN/hermes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0" "$@" > "$TEST_TMP/hermes-args"
EOF
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/hermes"
rm -f "$TEST_TMP/tmux-args"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/hermes-stderr"

expected_tmux_args=$'rename-window\n--\nhermes'
actual_tmux_args=$(cat "$TEST_TMP/tmux-args")
[[ "$actual_tmux_args" == "$expected_tmux_args" ]] \
    || { echo "FAIL: resume did not set the Hermes tmux title: $actual_tmux_args" >&2; exit 1; }

expected_hermes_args=$(printf '%s\nchat\n--resume\n20240706_120000_hermes' "$FAKE_BIN/hermes")
actual_hermes_args=$(cat "$TEST_TMP/hermes-args")
[[ "$actual_hermes_args" == "$expected_hermes_args" ]] \
    || { echo "FAIL: resume did not dispatch Hermes: $actual_hermes_args" >&2; exit 1; }

# Grok Build stores sessions under ~/.grok/sessions/<url-encoded-cwd>/<id>/
# with summary.json. Empty sessions (no chat turns, no title) must stay out
# of the picker; real sessions resume via `grok --resume <id>`.
gkid="019f80cb-55c4-72a0-a994-e8687e2832d0"
gkcwd="$HOME/grok-proj"
gkdir="$HOME/.grok/sessions/%2Ftmp%2Fgrok-proj/$gkid"
mkdir -p "$gkcwd" "$gkdir" "$HOME/.grok/sessions/%2Ftmp%2Fempty/019f0000-0000-7000-8000-000000000000"
cat > "$gkdir/summary.json" <<EOF
{
  "info": {"id": "$gkid", "cwd": "$gkcwd"},
  "session_summary": "Resume Grok work",
  "generated_title": "Resume Grok work",
  "created_at": "2024-07-07T12:00:00.000000Z",
  "updated_at": "2024-07-07T12:00:00.000000Z",
  "last_active_at": "2024-07-07T12:00:00.000000Z",
  "num_chat_messages": 4,
  "num_messages": 10
}
EOF
cat > "$HOME/.grok/sessions/%2Ftmp%2Fempty/019f0000-0000-7000-8000-000000000000/summary.json" <<'EOF'
{
  "info": {"id": "019f0000-0000-7000-8000-000000000000", "cwd": "/tmp/empty"},
  "session_summary": "",
  "generated_title": "",
  "created_at": "2024-07-07T13:00:00.000000Z",
  "updated_at": "2024-07-07T13:00:00.000000Z",
  "num_chat_messages": 0,
  "num_messages": 0
}
EOF

cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
selection=$(cat)
[[ "$selection" != *"019f0000-0000-7000-8000-000000000000"* ]] || exit 2
printf '%s\n' "$selection" | grep 'gk|' | head -1
EOF
cat > "$FAKE_BIN/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0" "$@" > "$TEST_TMP/grok-args"
EOF
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/grok"
rm -f "$TEST_TMP/tmux-args"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/grok-stderr"

expected_tmux_args=$'rename-window\n--\ngrok'
actual_tmux_args=$(cat "$TEST_TMP/tmux-args")
[[ "$actual_tmux_args" == "$expected_tmux_args" ]] \
    || { echo "FAIL: resume did not set the Grok tmux title: $actual_tmux_args" >&2; exit 1; }

expected_grok_args=$(printf '%s\n--resume\n%s' "$FAKE_BIN/grok" "$gkid")
actual_grok_args=$(cat "$TEST_TMP/grok-args")
[[ "$actual_grok_args" == "$expected_grok_args" ]] \
    || { echo "FAIL: resume did not dispatch Grok: $actual_grok_args" >&2; exit 1; }

# Kimi Code stores sessions under ~/.kimi-code/sessions/<workDirKey>/<id>/
# with state.json (title + timestamps); session_index.jsonl maps the session
# to its working directory. Sessions without a title must stay out of the
# picker; real sessions resume via `kimi --session <id>`.
kmid="session_8a0c1def-382d-4693-bba9-68cccb63753d"
kmcwd="$HOME/kimi-proj"
kmdir="$HOME/.kimi-code/sessions/wd_kimi-proj_aabbccddeeff/$kmid"
mkdir -p "$kmcwd" "$kmdir" "$HOME/.kimi-code/sessions/wd_empty_001122334455/session_00000000-0000-4000-8000-000000000000"
cat > "$kmdir/state.json" <<'EOF'
{
  "createdAt": "2024-07-08T12:00:00.000Z",
  "updatedAt": "2024-07-08T12:30:00.000Z",
  "title": "Resume Kimi work",
  "isCustomTitle": false
}
EOF
cat > "$HOME/.kimi-code/sessions/wd_empty_001122334455/session_00000000-0000-4000-8000-000000000000/state.json" <<'EOF'
{
  "createdAt": "2024-07-08T13:00:00.000Z",
  "updatedAt": "2024-07-08T13:00:00.000Z",
  "title": "",
  "isCustomTitle": false
}
EOF
cat > "$HOME/.kimi-code/session_index.jsonl" <<EOF
{"sessionId":"$kmid","sessionDir":"$kmdir","workDir":"$kmcwd"}
EOF

cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
selection=$(cat)
[[ "$selection" != *"session_00000000-0000-4000-8000-000000000000"* ]] || exit 2
printf '%s\n' "$selection" | grep 'km|' | head -1
EOF
cat > "$FAKE_BIN/kimi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0" "$@" > "$TEST_TMP/kimi-args"
EOF
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/kimi"
rm -f "$TEST_TMP/tmux-args"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/kimi-stderr"

expected_tmux_args=$'rename-window\n--\nkimi'
actual_tmux_args=$(cat "$TEST_TMP/tmux-args")
[[ "$actual_tmux_args" == "$expected_tmux_args" ]] \
    || { echo "FAIL: resume did not set the Kimi tmux title: $actual_tmux_args" >&2; exit 1; }

expected_kimi_args=$(printf '%s\n--session\n%s' "$FAKE_BIN/kimi" "$kmid")
actual_kimi_args=$(cat "$TEST_TMP/kimi-args")
[[ "$actual_kimi_args" == "$expected_kimi_args" ]] \
    || { echo "FAIL: resume did not dispatch Kimi: $actual_kimi_args" >&2; exit 1; }

# Native Kimi installs live below KIMI_CODE_HOME. Resume must still dispatch
# them when the caller did not inherit that private bin directory on PATH.
mkdir -p "$HOME/.kimi-code/bin"
mv "$FAKE_BIN/kimi" "$HOME/.kimi-code/bin/kimi"
rm -f "$TEST_TMP/kimi-args" "$TEST_TMP/tmux-args"
TMUX=test-session PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/kimi-private-stderr"
expected_kimi_args=$(printf '%s\n--session\n%s' "$HOME/.kimi-code/bin/kimi" "$kmid")
actual_kimi_args=$(cat "$TEST_TMP/kimi-args")
[[ "$actual_kimi_args" == "$expected_kimi_args" ]] \
    || { echo "FAIL: resume did not dispatch private Kimi: $actual_kimi_args" >&2; exit 1; }
[[ $(cat "$TEST_TMP/tmux-args") == $'rename-window\n--\nkimi' ]] \
    || { echo "FAIL: private Kimi path leaked into the tmux title" >&2; exit 1; }

echo "resume format tests passed"
