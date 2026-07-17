#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export STATE_DIR="$XDG_STATE_HOME/setup"
export SETUP_SOURCE_ONLY=1
mkdir -p "$HOME/.bashrc.d" "$STATE_DIR" "$TEST_TMP/bin"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

zsh_bin=$(command -v zsh 2>/dev/null) || {
    echo "ai-menu tests skipped (zsh unavailable)"
    exit 0
}

# shellcheck disable=SC1091
source "$ROOT/bin/setup"
# shellcheck disable=SC1091
source "$ROOT/files/ai-menu.sh"
cp "$ROOT/files/ai-menu" "$PAYLOAD_TARGET"
manage_block "$HOME/.zshrc" ai-menu "$BLOCK_CONTENT" upsert append >/dev/null

cat > "$TEST_TMP/bin/fzf" <<'EOF'
#!/bin/sh
printf 'launched\n' >> "$AI_MENU_TEST_LOG"
EOF
chmod +x "$TEST_TMP/bin/fzf"

run_zsh() {
    AI_MENU_TEST_LOG="$TEST_TMP/launches" PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        ZDOTDIR="$HOME" "$zsh_bin" -i -c "$1" >/dev/null 2>&1
}

run_ai() {
    AI_MENU_TEST_LOG="$TEST_TMP/launches" PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        "$zsh_bin" -f -c 'source "$1"; shift; ai "$@"' zsh "$PAYLOAD_TARGET" "$@" >/dev/null 2>&1
}

block_hash_before=$(_state_hash)
run_ai disable
[[ -e "$STATE_DIR/ai-menu-autolaunch-disabled" ]] \
    || fail "ai disable did not persist the disabled state"
run_zsh 'exit'
[[ ! -e "$TEST_TMP/launches" ]] \
    || fail "a disabled ai-menu auto-launched during shell startup"
run_ai
[[ $(wc -l < "$TEST_TMP/launches") -eq 1 ]] \
    || fail "ai disable blocked an explicit ai invocation"
run_ai disable
[[ $(_state_hash) == "$block_hash_before" ]] \
    || fail "ai disable changed the managed payload or block hash"

rm -f "$TEST_TMP/launches"
run_ai enable
[[ ! -e "$STATE_DIR/ai-menu-autolaunch-disabled" ]] \
    || fail "ai enable did not clear the disabled state"
run_zsh 'exit'
[[ $(wc -l < "$TEST_TMP/launches") -eq 1 ]] \
    || fail "an enabled ai-menu did not auto-launch during shell startup"
run_ai enable
[[ $(_state_hash) == "$block_hash_before" ]] \
    || fail "ai enable changed the managed payload or block hash"

# Span-aware path: semantic three-column records, three 2-track action rows
# with folder-overflow cells beside them, hidden metadata stripped before
# setup dispatch, and physical-row-based height.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/fzf-multicolumn" <<'EOF'
#!/bin/sh
case "$1" in
    --help) echo '--grid-span-prefix=STR'; exit ;;
esac
input=$(cat)
printf '%s\n' "$input" > "$AI_MENU_GRID_INPUT"
printf '%s\n' "$*" > "$AI_MENU_GRID_ARGS"
printf 'action\037setup\037setup\n'
EOF
cat > "$TEST_TMP/bin/setup" <<'EOF'
#!/bin/sh
printf 'setup-dispatched\n' >> "$AI_MENU_TEST_LOG"
EOF
chmod +x "$HOME/.local/bin/fzf-multicolumn" "$TEST_TMP/bin/setup"
rm -f "$TEST_TMP/launches"
AI_MENU_TEST_LOG="$TEST_TMP/launches" AI_MENU_GRID_INPUT="$TEST_TMP/grid-input" \
AI_MENU_GRID_ARGS="$TEST_TMP/grid-args" PATH="$TEST_TMP/bin:/usr/bin:/bin" \
    "$zsh_bin" -f -c 'source "$1"; ai' zsh "$PAYLOAD_TARGET" >/dev/null 2>&1
[[ $(grep -c '^@@2@@action' "$TEST_TMP/grid-input") -eq 3 ]] \
    || fail "setup/resume/neither were not three 2-track span rows"
grep -q -- '--grid=3' "$TEST_TMP/grid-args" || fail "ai-menu did not request a three-column grid"
grep -q -- '--grid-span-prefix=@@' "$TEST_TMP/grid-args" || fail "ai-menu omitted span prefix"
grep -q 'setup-dispatched' "$TEST_TMP/launches" || fail "typed setup metadata was not stripped for dispatch"

# A pre-capable binary triggers repair on every invocation (no permanent failed
# marker); if repair does not fix it, ai-menu falls back to plain fzf.
cat > "$HOME/.local/bin/fzf-multicolumn" <<'EOF'
#!/bin/sh
echo '--grid=COLS'
EOF
cat > "$TEST_TMP/bin/setup" <<'EOF'
#!/bin/sh
printf 'repair-attempt\n' >> "$AI_MENU_TEST_LOG"
EOF
cat > "$TEST_TMP/bin/fzf" <<'EOF'
#!/bin/sh
cat >/dev/null
printf 'neither\n'
EOF
chmod +x "$HOME/.local/bin/fzf-multicolumn" "$TEST_TMP/bin/setup" "$TEST_TMP/bin/fzf"
rm -f "$TEST_TMP/launches"
run_ai
run_ai
[[ $(grep -c repair-attempt "$TEST_TMP/launches") -eq 2 ]] \
    || fail "ai-menu failure became permanently marked or did not retry repair"
[[ ! -e "$STATE_DIR/ai-menu-grid-attempted" ]] || fail "legacy permanent failure marker was recreated"

echo "ai-menu tests passed"
