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

expected_claudex_args=$(printf '%s\nrun\ncodex\n--config\n%s/.config/claudex/config.toml\n--resume\n%s' \
    "$FAKE_BIN/claudex" "$HOME" "$cxid")
actual_claudex_args=$(cat "$TEST_TMP/claudex-args")
[[ "$actual_claudex_args" == "$expected_claudex_args" ]] \
    || { echo "FAIL: resume did not dispatch claudex for a claudex-proxy session: $actual_claudex_args" >&2; exit 1; }

echo "resume format tests passed"
