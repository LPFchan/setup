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

# The harnesses module owns harness updating end to end: `harnesses update`
# runs the self-updaters and `harnesses schedule` installs the timer that
# calls it. setup must not reach into that anymore. This stub stands in for
# the installed client and records anything setup sends it.
make_harnesses_client() {
    local rc="${1:-0}"
    cat > "$HOME/.local/bin/harnesses" <<EOF
#!/usr/bin/env zsh
printf "harnesses %s\n" "\$*" >> "$CALLS"
exit $rc
EOF
    chmod +x "$HOME/.local/bin/harnesses"
}

# --- cmd_update integration -----------------------------------------
# `setup update` is a module updater and nothing else. The daily timer calls
# it with no arguments, so that form must not quietly drive the harnesses.
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
harnesses	~/.local/bin/harnesses	0755	harnesses-stub
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
if grep -q "harnesses update" "$CALLS"; then
    fail "bare setup update still ran the harness self-updaters"
fi

run_update tmux || fail "module-filtered update failed: $(cat "$TMP/out")"
grep -qx "module tmux" "$CALLS" || fail "module-filtered update skipped its module"
if grep -qx "module harnesses" "$CALLS"; then fail "module-filtered update touched other modules"; fi

# `harnesses` is a module like any other: filtering on it updates the module,
# not the per-harness self-updaters.
run_update harnesses || fail "harnesses-module update failed: $(cat "$TMP/out")"
grep -qx "module harnesses" "$CALLS" || fail "setup update harnesses skipped the module itself"
if grep -q "harnesses update" "$CALLS"; then
    fail "setup update harnesses ran the harness self-updaters instead of the module"
fi
[[ -s "$FETCHES" ]] || fail "setup update harnesses did not fetch the manifest"

run_update tmux harnesses || fail "combined update failed: $(cat "$TMP/out")"
grep -qx "module tmux" "$CALLS" || fail "combined update skipped tmux"
grep -qx "module harnesses" "$CALLS" || fail "combined update skipped harnesses"
if grep -q "harnesses update" "$CALLS"; then
    fail "a filtered update still pulled in the harness self-updaters"
fi

# A broken harnesses client cannot fail a module update any longer, because
# setup never calls it.
make_harnesses_client 1
run_update || fail "a failing harnesses client broke an unrelated module update"
grep -q "All modules up to date" "$TMP/out" \
    || fail "module summary missing: $(cat "$TMP/out")"

# --- setup's service-module wiring ------------------------------------
# setup enable/disable/status drive the module's own timer, the same way they
# already drive the providers timer.
unset -f is_service_module
is_service_module() {
    local m
    for m in ${SERVICE_MODULES}; do [[ "$m" == "$1" ]] && return 0; done
    return 1
}
is_service_module harnesses || fail "harnesses is not registered as a service module"
[[ "$(module_service_unit harnesses)" == harnesses-update.timer ]] \
    || fail "harnesses service unit is wrong: $(module_service_unit harnesses)"
[[ "$(module_enable_cmd harnesses)" == *"harnesses schedule" ]] \
    || fail "setup enable harnesses does not call the module: $(module_enable_cmd harnesses)"
[[ "$(module_disable_cmd harnesses)" == *"harnesses schedule disable" ]] \
    || fail "setup disable harnesses does not call the module: $(module_disable_cmd harnesses)"

echo "ok"
