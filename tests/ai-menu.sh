#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

echo "ai-menu tests passed"
