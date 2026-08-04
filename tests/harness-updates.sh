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

# A harness stub records how it was invoked. $2 is the exit code it reports.
# Not `local path=` — that name is tied to zsh's PATH.
make_harness() {
    local bin="$1" rc="${2:-0}"
    mkdir -p "$(dirname "$bin")"
    cat > "$bin" <<EOF
#!/usr/bin/env zsh
printf '%s %s\n' "\${0:t}" "\$*" >> "$CALLS"
exit $rc
EOF
    chmod +x "$bin"
}

# Vendor install prefixes, none of them on PATH — this is what the systemd user
# timer sees when it runs 'setup update'.
make_harness "$HOME/.local/bin/claude"
make_harness "$HOME/.opencode/bin/opencode"
make_harness "$HOME/.local/bin/agy"
make_harness "$HOME/.local/bin/hermes"
make_harness "$HOME/.grok/bin/grok"
make_harness "$HOME/.kimi-code/bin/kimi"

# codex is an npm global inside an nvm prefix, and is a node script: it cannot
# run unless node — which lives beside it, off PATH — is reachable.
node_bin="$HOME/.nvm/versions/node/v22.23.1/bin"
mkdir -p "$node_bin"
cat > "$node_bin/codex" <<EOF
#!/usr/bin/env zsh
# The node beside codex must win, not any node already on PATH.
[[ "\$(command -v node 2>/dev/null)" == "$node_bin/node" ]] || exit 127
printf '%s %s\n' "\${0:t}" "\$*" >> "$CALLS"
EOF
chmod +x "$node_bin/codex"
printf '#!/usr/bin/env zsh\nexit 0\n' > "$node_bin/node"
chmod +x "$node_bin/node"

# A minimal PATH holding neither the vendor prefixes nor the node prefix proves
# resolution never depends on PATH — and would find the tester's own harnesses
# if it did.
PATH=/usr/bin:/bin cmd_update_harnesses > "$TMP/out" 2>&1 \
    || fail "all-present run reported failure: $(cat "$TMP/out")"

for expected in \
    'claude update' \
    'codex update' \
    'opencode upgrade' \
    'agy update' \
    'hermes update --yes' \
    'grok update' \
    'kimi update'
do
    grep -qx "$expected" "$CALLS" || fail "missing invocation: $expected (got: $(tr '\n' '; ' < "$CALLS"))"
done
(( $(wc -l < "$CALLS") == 7 )) || fail "unexpected extra invocations: $(tr '\n' '; ' < "$CALLS")"

# A harness that is not installed is skipped, not an error.
rm "$HOME/.grok/bin/grok" "$HOME/.kimi-code/bin/kimi"
: > "$CALLS"
PATH=/usr/bin:/bin cmd_update_harnesses > "$TMP/out" 2>&1 \
    || fail "run with missing harnesses reported failure: $(cat "$TMP/out")"
grep -q 'Not installed, skipped: grok kimi' "$TMP/out" \
    || fail "missing harnesses were not reported as skipped: $(cat "$TMP/out")"
(( $(wc -l < "$CALLS") == 5 )) || fail "skipped harnesses were still invoked"

# A failing updater is reported by name and does not stop the others.
make_harness "$HOME/.local/bin/agy" 1
: > "$CALLS"
if PATH=/usr/bin:/bin cmd_update_harnesses > "$TMP/out" 2>&1; then
    fail "failing harness did not fail the run"
fi
[[ "${HARNESS_FAILED_NAMES[*]}" == agy ]] || fail "failed harness not recorded: ${HARNESS_FAILED_NAMES[*]}"
grep -qx 'hermes update --yes' "$CALLS" || fail "a failing harness aborted the remaining updates"

# No harnesses at all is a clean no-op.
rm -rf "$HOME/.local/bin/claude" "$HOME/.local/bin/agy" "$HOME/.local/bin/hermes" \
       "$HOME/.opencode" "$HOME/.nvm"
: > "$CALLS"
PATH=/usr/bin:/bin cmd_update_harnesses > "$TMP/out" 2>&1 \
    || fail "empty machine reported failure: $(cat "$TMP/out")"
grep -q 'No AI harnesses installed' "$TMP/out" || fail "empty machine not reported: $(cat "$TMP/out")"
[[ ! -s "$CALLS" ]] || fail "invocations happened on an empty machine"

# --- cmd_update integration -----------------------------------------
# Which of the two halves (manifest modules, harnesses) a given argument list
# runs. The daily timer calls `setup update` with no arguments, so that form
# must cover both.

make_harness "$HOME/.local/bin/claude"
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
installed_hash_for() { printf 'installed\n'; }
install_one() { printf 'module %s\n' "$1" >> "$CALLS"; }
is_service_module() { return 1; }

run_update() {
    : > "$CALLS"; : > "$FETCHES"
    PATH=/usr/bin:/bin cmd_update "$@" > "$TMP/out" 2>&1
}

run_update || fail "bare update failed: $(cat "$TMP/out")"
grep -qx 'module tmux' "$CALLS" || fail "bare update skipped manifest modules"
grep -qx 'claude update' "$CALLS" || fail "bare update skipped harnesses"

run_update tmux || fail "module-filtered update failed: $(cat "$TMP/out")"
grep -qx 'module tmux' "$CALLS" || fail "module-filtered update skipped its module"
if grep -q 'claude' "$CALLS"; then fail "module-filtered update pulled in harnesses"; fi

run_update harnesses || fail "harness-filtered update failed: $(cat "$TMP/out")"
grep -qx 'claude update' "$CALLS" || fail "harness-filtered update skipped harnesses"
if grep -q 'module ' "$CALLS"; then fail "harness-filtered update touched manifest modules"; fi
[[ ! -s "$FETCHES" ]] || fail "harness-filtered update fetched the manifest"

run_update tmux harnesses || fail "combined update failed: $(cat "$TMP/out")"
grep -qx 'module tmux' "$CALLS" || fail "combined update skipped its module"
grep -qx 'claude update' "$CALLS" || fail "combined update skipped harnesses"

# A harness failure alone must fail `setup update`, so the timer's journal
# entry shows it.
make_harness "$HOME/.local/bin/claude" 1
if run_update; then fail "failing harness did not fail cmd_update"; fi
grep -q '1 harness(es) could not be updated: claude' "$TMP/out" \
    || fail "harness failure missing from the update summary: $(cat "$TMP/out")"
grep -q 'All modules up to date' "$TMP/out" \
    || fail "module summary lost when a harness failed: $(cat "$TMP/out")"

echo "ok"
