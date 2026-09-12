#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" SETUP_SOURCE_ONLY=1
mkdir -p "$HOME/.local/bin" "$XDG_STATE_HOME/setup"
# shellcheck disable=SC1091
source "$ROOT/bin/setup"

fail() { echo "FAIL: $*" >&2; exit 1; }

CALLS="$TMP/calls"
: > "$CALLS"

# The harness self-update logic moved out of bin/setup into the harnesses
# module. cmd_update_harnesses now locates ~/.local/bin/harnesses and hands
# the work to it. These stubs stand in for that client.
make_harnesses_client() {
    local rc="${1:-0}"
    cat > "$HOME/.local/bin/harnesses" <<EOF
#!/usr/bin/env zsh
printf "harnesses %s\\n" "\$*" >> "$CALLS"
exit $rc
EOF
    chmod +x "$HOME/.local/bin/harnesses"
}

# With no client installed the delegation is a clean no-op (the module simply
# is not present on this machine yet).
rm -f "$HOME/.local/bin/harnesses"
cmd_update_harnesses > "$TMP/out" 2>&1 \
    || fail "absent harnesses client reported failure: $(cat "$TMP/out")"
grep -q "harnesses module not installed" "$TMP/out" \
    || fail "absent client was not signposted: $(cat "$TMP/out")"
[[ ! -s "$CALLS" ]] || fail "a missing client was still invoked"

# With a client present the update is delegated to it.
make_harnesses_client 0
cmd_update_harnesses > "$TMP/out" 2>&1 \
    || fail "delegated update reported failure: $(cat "$TMP/out")"
grep -qx "harnesses update" "$CALLS" \
    || fail "update was not delegated to the harnesses client: $(tr "\n" "; " < "$CALLS")"

# A failing client fails the run so the timer journal shows it.
make_harnesses_client 1
if cmd_update_harnesses > "$TMP/out" 2>&1; then
    fail "failing client did not fail cmd_update_harnesses"
fi

# --- cmd_update integration -----------------------------------------
# Which of the two halves (manifest modules, harnesses) a given argument list
# runs. The daily timer calls `setup update` with no arguments, so that form
# must cover both.
make_harnesses_client 0
FETCHES="$TMP/fetches"
: > "$FETCHES"
configure_shell() { :; }
normalize_block_order() { :; }
fetch_manifest() {
    echo fetched >> "$FETCHES"
    cat > "$MANIFEST_FILE" <<'EOF'
# module	target	mode	source
tmux	~/.local/bin/tmux-stub	0755	tmux
EOF
}
installed_hash_for() { printf "installed\n"; }
install_one() { printf "module %s\n" "$1" >> "$CALLS"; }
is_service_module() { return 1; }

run_update() {
    : > "$CALLS"; : > "$FETCHES"
    PATH=/usr/bin:/bin cmd_update "$@" > "$TMP/out" 2>&1
}

run_update || fail "bare update failed: $(cat "$TMP/out")"
grep -qx "module tmux" "$CALLS" || fail "bare update skipped manifest modules"
grep -qx "harnesses update" "$CALLS" || fail "bare update skipped harnesses"

run_update tmux || fail "module-filtered update failed: $(cat "$TMP/out")"
grep -qx "module tmux" "$CALLS" || fail "module-filtered update skipped its module"
if grep -q "harnesses update" "$CALLS"; then fail "module-filtered update pulled in harnesses"; fi

run_update harnesses || fail "harness-filtered update failed: $(cat "$TMP/out")"
grep -qx "harnesses update" "$CALLS" || fail "harness-filtered update skipped harnesses"
if grep -q "module " "$CALLS"; then fail "harness-filtered update touched manifest modules"; fi
[[ ! -s "$FETCHES" ]] || fail "harness-filtered update fetched the manifest"

run_update tmux harnesses || fail "combined update failed: $(cat "$TMP/out")"
grep -qx "module tmux" "$CALLS" || fail "combined update skipped its module"
grep -qx "harnesses update" "$CALLS" || fail "combined update skipped harnesses"

# A harness failure alone must fail `setup update`, so the timer journal shows it.
make_harnesses_client 1
if run_update; then fail "failing harness did not fail cmd_update"; fi
grep -q "All modules up to date" "$TMP/out" \
    || fail "module summary lost when a harness failed: $(cat "$TMP/out")"

echo "ok"
