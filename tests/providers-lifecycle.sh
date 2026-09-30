#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export PROVIDERS_BIN="$HOME/.local/bin/providers"
export PROVIDERS_REGISTRY="$HOME/.config/providers/registry.json"
export PROVIDERS_SOURCE="$ROOT/files/providers"
export PROVIDER_REGISTRY_SOURCE="$ROOT/files/provider-registry.json"
mkdir -p "$XDG_STATE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/providers.sh"

expect_status() {
    local expected_rc="$1" expected_word="$2" output rc=0
    output=$(status) || rc=$?
    [[ "$rc" == "$expected_rc" ]] || fail "status returned $rc, expected $expected_rc: $output"
    [[ "$output" == *"$expected_word"* ]] || fail "status omitted $expected_word: $output"
}

mkdir -p "${BIN:h}"
cp "$ROOT/files/providers" "$BIN"
chmod +x "$BIN"
expect_status 1 outdated

install
[[ -x "$BIN" ]] || fail "standalone install omitted the launcher"
[[ -f "$REGISTRY" ]] || fail "standalone install omitted the provider registry"
expect_status 0 current

print '# drift' >> "$BIN"
expect_status 1 outdated
update
expect_status 0 current

uninstall
[[ ! -e "$REGISTRY" ]] || fail "uninstall left the provider registry behind"

# Unreadable provider state fails the install instead of being overwritten.
mkdir -p "$HOME/.config/providers"
print '{truncated' > "$HOME/.config/providers/state.json"
rc=0
install >/dev/null 2>&1 || rc=$?
(( rc != 0 )) || fail "install reported success despite unreadable provider state"
[[ "$(<"$HOME/.config/providers/state.json")" == '{truncated' ]] \
    || fail "a failed install rewrote the provider state"
rm -f "$HOME/.config/providers/state.json"

install
expect_status 0 current
uninstall
[[ ! -e "$REGISTRY" ]] || fail "uninstall left the provider registry behind"

echo "providers lifecycle tests passed"
