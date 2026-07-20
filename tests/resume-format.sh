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
cat > "$FAKE_BIN/find" <<'EOF'
#!/usr/bin/env bash
sleep 0.2
[[ -e "$TEST_TMP/fzf-started" ]] || printf 'fzf did not start before scan emitted data\n' > "$TEST_TMP/async-failure"
exec /usr/bin/find "$@"
EOF
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/find"
PATH="$FAKE_BIN:$PATH"
export PATH

session="$HOME/.codex/sessions/rollout-2024-07-03T18-46-40-test-session.jsonl"
cat > "$session" <<'EOF'
{"payload":{"thread_source":"","cwd":"/tmp/project"}}
{"type":"response_item","role":"user","payload":{"content":[{"type":"input_text","text":"Fix timestamp display"}]}}
EOF
touch -t 202407031846.40 "$session"

if "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/stderr"; then
    echo "FAIL: fake fzf should cancel resume" >&2
    exit 1
fi

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

# A claude session launched through claudex lands under ~/.claude/projects like
# any native claude session, distinguished only by assistant turns recording
# model "claudex-proxy". resume must tag it clx and relaunch it via
# `claudex run codex --config <cfg> --resume <id>` (codex backend), not bare
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

expected_claudex_args=$(printf '%s\nrun\ncodex\n--config\n%s/.config/claudex/config.toml\n--dangerously-skip-permissions\n--resume\n%s' \
    "$FAKE_BIN/claudex" "$HOME" "$cxid")
actual_claudex_args=$(cat "$TEST_TMP/claudex-args")
[[ "$actual_claudex_args" == "$expected_claudex_args" ]] \
    || { echo "FAIL: resume did not dispatch claudex for a claudex-proxy session: $actual_claudex_args" >&2; exit 1; }

# A claudex-proxy session mapped to the "commandcode" profile (via
# ~/.config/claudex/sessions.tsv) must resume via `claudex run commandcode`,
# not `claudex run codex`. The mapping is written by _claudex_launch in
# ai-menu and read by _claudex_profile_for in resume.
ccid="aaaaaaaa-bbbb-cccc-dddd-ffffffffffff"
cccwd="$HOME/cc-proj"
mkdir -p "$cccwd" "$HOME/.claude/projects/-home-cc-proj"
ccsession="$HOME/.claude/projects/-home-cc-proj/$ccid.jsonl"
{
    printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"Command code session"}}\n' "$cccwd"
    printf '{"type":"assistant","message":{"role":"assistant","model":"claudex-proxy","content":[{"type":"text","text":"ok"}]}}\n'
} > "$ccsession"
touch -t 202407051200.00 "$ccsession"

# Write the sidecar mapping so resume knows this is a commandcode session
mkdir -p "$HOME/.config/claudex"
printf '%s\t%s\n' "$ccid" "commandcode" > "$HOME/.config/claudex/sessions.tsv"

# fzf stub that selects exactly the claudex-cc row (its hidden ref carries "clxcc|")
cat > "$FAKE_BIN/fzf" <<'EOF'
#!/usr/bin/env bash
selection=$(cat)
printf '%s\n' "$selection" | grep 'clxcc|' | head -1
EOF
chmod +x "$FAKE_BIN/fzf"
rm -f "$TEST_TMP/tmux-args" "$TEST_TMP/claudex-args"

TMUX=test-session "$ROOT/files/resume" >/dev/null 2>"$TEST_TMP/claudex-cc-stderr"

expected_cc_args=$(printf '%s\nrun\ncommandcode\n--config\n%s/.config/claudex/config.toml\n--dangerously-skip-permissions\n--resume\n%s' \
    "$FAKE_BIN/claudex" "$HOME" "$ccid")
actual_cc_args=$(cat "$TEST_TMP/claudex-args")
[[ "$actual_cc_args" == "$expected_cc_args" ]] \
    || { echo "FAIL: resume did not dispatch claudex with commandcode profile: $actual_cc_args" >&2; exit 1; }

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

echo "resume format tests passed"
