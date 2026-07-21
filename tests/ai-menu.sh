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

# --- Recency store: stamp / read / cap / HOME-skip / bubble / cold-start ----
# The store functions are called directly (like run_ai sources the payload),
# with $PWD controlled per invocation so we can exercise stamping specific dirs.
STORE="$STATE_DIR/ai-menu-dirs"
DIRS="$TEST_TMP/dirs"
mkdir -p "$DIRS"

# stamp_dir <abs-pwd>: source the payload, cd into it, stamp once.
stamp_dir() {
    PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        "$zsh_bin" -f -c 'source "$1"; cd "$2" || exit; _ai_stamp_recent_dir' \
        zsh "$PAYLOAD_TARGET" "$1" >/dev/null 2>&1
}
# read_dirs <max>: source the payload and emit the recency column to stdout.
read_dirs() {
    PATH="$TEST_TMP/bin:/usr/bin:/bin" \
        "$zsh_bin" -f -c 'source "$1"; _ai_recent_dirs "$2"' \
        zsh "$PAYLOAD_TARGET" "${1:-10}" 2>/dev/null
}

# (a) Stamping a non-HOME $PWD writes it to the store and it reads back first.
rm -f "$STORE"
mkdir -p "$DIRS/alpha" "$DIRS/beta"
stamp_dir "$DIRS/alpha"
stamp_dir "$DIRS/beta"
[[ -f "$STORE" ]] || fail "stamping a dir did not create the recency store"
[[ "$(read_dirs 10 | head -1)" == "$DIRS/beta" ]] \
    || fail "most-recently-stamped dir did not read back first"
[[ $(read_dirs 10 | grep -c "$DIRS/alpha") -eq 1 ]] \
    || fail "an earlier-stamped dir dropped out of the store"

# (b) Stamping $PWD == $HOME leaves the store byte-for-byte unchanged.
store_before="$(cat "$STORE")"
stamp_dir "$HOME"
[[ "$(cat "$STORE")" == "$store_before" ]] \
    || fail "stamping \$HOME modified the recency store"

# (c) Re-stamping an older dir bubbles it back to the top (pure recency).
stamp_dir "$DIRS/alpha"
[[ "$(read_dirs 10 | head -1)" == "$DIRS/alpha" ]] \
    || fail "re-stamped dir did not bubble to the top"

# (d) The store grows unbounded (deduped by distinct dir); only the load/display
# is capped, via the $max arg to _ai_recent_dirs. Stamp 12 distinct dirs: all 12
# survive in the store, but a bounded read returns only that many rows.
rm -f "$STORE"
n=12
for i in $(seq 1 $n); do
    mkdir -p "$DIRS/big$i"
    stamp_dir "$DIRS/big$i"
done
[[ $(wc -l < "$STORE") -eq $n ]] \
    || fail "recency store evicted distinct dirs instead of growing to $n"
grep -q "$DIRS/big1\$" "$STORE" \
    || fail "oldest distinct dir was evicted from the unbounded store"
# _ai_recent_dirs exits nonzero when the list is shorter than max (as the
# original did); capture first so the harness's pipefail doesn't misread it.
[[ $(read_dirs 5 | wc -l) -eq 5 ]] \
    || fail "read did not cap display to the requested row count"
big_out="$(read_dirs 5)"
[[ "$(printf '%s\n' "$big_out" | head -1)" == "$DIRS/big$n" ]] \
    || fail "capped read did not return the newest dirs first"

# (e) Cold-start seed from $history when the store is absent/empty. fc -R drops
# the final history line (a zsh quirk), so a throwaway sentinel goes last.
rm -f "$STORE"
mkdir -p "$DIRS/hist1" "$DIRS/hist2"
printf 'cd %s\ncd %s\ncd /nonexistent-ai-menu-sentinel\n' \
    "$DIRS/hist1" "$DIRS/hist2" > "$HOME/.zsh_history"
seed_out="$(read_dirs 10)"
[[ "$(printf '%s\n' "$seed_out" | head -1)" == "$DIRS/hist2" ]] \
    || fail "cold-start seed did not surface the newest history dir first"
printf '%s\n' "$seed_out" | grep -q "$DIRS/hist1\$" \
    || fail "cold-start seed omitted an older history dir"
[[ -f "$STORE" ]] || fail "cold-start seed did not persist the store"
rm -f "$HOME/.zsh_history"

echo "ai-menu tests passed"
