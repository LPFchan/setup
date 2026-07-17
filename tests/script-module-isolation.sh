#!/usr/bin/env zsh
# Regression test: script-module payloads must not leak their
# install/update/status/uninstall functions into the setup process.
# A leaked `install` shadowed /usr/bin/install and made every later
# file-module write (including setup's own self-update) a silent no-op
# while record_hash still recorded the new hash ("modified" drift).
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export LINUX_SETUP_SOURCE_URL="file://$ROOT"
export SETUP_SOURCE_ONLY=1
mkdir -p "$HOME" "$XDG_STATE_HOME"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck disable=SC1091
source "$ROOT/bin/setup"

# --- run_script_payload must not leak module functions or globals ---

payload="$TEST_TMP/payload.sh"
cat > "$payload" <<'EOF'
# setup-module: fake-module
MODULE_LEAK_CANARY=leaked
install() {
    echo "hijacked install: $*"
    touch "$TEST_TMP/hijack-ran"
}
update() { install; }
EOF

run_script_payload "$payload" install >/dev/null \
    || fail "run_script_payload could not run the payload's install()"
[[ -f "$TEST_TMP/hijack-ran" ]] \
    || fail "payload install() did not run inside the subshell"

(( ${+functions[install]} )) \
    && fail "install() leaked into the parent process"
(( ${+functions[update]} )) \
    && fail "update() leaked into the parent process"
[[ -z "${MODULE_LEAK_CANARY:-}" ]] \
    || fail "payload globals leaked into the parent process"

run_script_payload "$payload" status 2>/dev/null \
    && fail "missing payload function should fail, not silently succeed"

# --- end-to-end: file-module install works after a script payload ran ---

run_script_payload "$payload" install >/dev/null
install_one kernel-simmer '~/.local/bin/kernel-simmer' 0755 bin/kernel-simmer \
    || fail "install_one failed after sourcing a script payload"
target="$HOME/.local/bin/kernel-simmer"
[[ -f "$target" ]] || fail "file module was never written to disk"
cmp -s "$target" "$ROOT/bin/kernel-simmer" \
    || fail "installed file does not match source (hijacked install?)"
recorded=$(installed_hash_for "$target")
[[ "$recorded" == "$(sha256 "$target")" ]] \
    || fail "recorded hash drifted from the file actually on disk"

# Defense in depth: even with a shadowing function forced into the parent,
# install_one must still write through to coreutils install.
install() { return 0; }
rm -f "$target"
install_one kernel-simmer '~/.local/bin/kernel-simmer' 0755 bin/kernel-simmer \
    || fail "install_one failed with a shadowing install() defined"
cmp -s "$target" "$ROOT/bin/kernel-simmer" \
    || fail "shadowing install() still hijacked install_one's write"
unset -f install

# --- manage_block upsert must be idempotent ---

conf="$HOME/.zshenv"
manage_block "$conf" testblock $'line one\nline two' upsert >/dev/null
out=$(manage_block "$conf" testblock $'line one\nline two' upsert)
[[ "$out" == "Current testblock -> $conf" ]] \
    || fail "unchanged block was rewritten: got '$out'"
out=$(manage_block "$conf" testblock $'line one\nline three' upsert)
[[ "$out" == "Updated $conf testblock" ]] \
    || fail "changed block was not rewritten: got '$out'"

echo "script module isolation tests passed"
