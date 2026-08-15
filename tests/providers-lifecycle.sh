#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export PROVIDERS_BIN="$HOME/.local/bin/providers"
export CLAUDEX_BIN="$HOME/.local/bin/claudex"
export PROVIDERS_REGISTRY="$HOME/.config/providers/registry.json"
export PROVIDERS_LEGACY_REGISTRY="$HOME/.config/claudex/managed-profiles.json"
export CLAUDEX_CONFIG="$HOME/.config/claudex/config.toml"
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

mkdir -p "$HOME/.config/opencode"
print '{"servers":{"commandcode":{"enabled":false}}}' \
    > "$HOME/.config/opencode/refresh-models.json"
# A stale retired registry path can be reclaimed during installation.
mkdir -p "${LEGACY_REGISTRY:h}"
cp "$ROOT/files/claudex-profiles.json" "$LEGACY_REGISTRY"
install
[[ -x "$BIN" ]] || fail "standalone install omitted the launcher"
[[ -f "$REGISTRY" ]] || fail "standalone install omitted the provider registry"
[[ ! -e "$LEGACY_REGISTRY" ]] || fail "install left the stale retired registry behind"
[[ -f "$HOME/.config/providers/state.json" ]] \
    || fail "install did not migrate provider enablement state"
[[ ! -e "$HOME/.config/opencode/refresh-models.json" ]] \
    || fail "install kept the obsolete provider registry"
grep -q '"version": 1' "$HOME/.config/providers/state.json" \
    || fail "migrated provider state omitted its schema version"
grep -q '"enabled": false' "$HOME/.config/providers/state.json" \
    || fail "install lost the legacy provider enablement state"
expect_status 0 current

print '# drift' >> "$BIN"
expect_status 1 outdated
update
expect_status 0 current

mkdir -p "${CLAUDEX_BIN:h}"
cp "$ROOT/files/claudex" "$CLAUDEX_BIN"
chmod +x "$CLAUDEX_BIN"
cp "$ROOT/files/claudex-profiles.json" "$LEGACY_REGISTRY"
update
[[ -f "$LEGACY_REGISTRY" ]] || fail "providers removed a registry owned by Claudex"
[[ ! -e "$CLAUDEX_CONFIG" ]] || fail "providers changed the co-installed Claudex config"

# A retired Claudex executable does not participate in provider updates.
print '#!/usr/bin/env python3\nraise SystemExit(3)' > "$CLAUDEX_BIN"
chmod +x "$CLAUDEX_BIN"
print '# drift' >> "$BIN"
expect_status 1 outdated
update 2>"$TEST_TMP/claudex.err" \
    || fail "a retired claudex aborted the providers update"
expect_status 0 current
[[ ! -s "$TEST_TMP/claudex.err" ]] \
    || fail "providers invoked the retired claudex executable"
cp "$ROOT/files/claudex" "$CLAUDEX_BIN"
chmod +x "$CLAUDEX_BIN"

uninstall
[[ ! -e "$REGISTRY" ]] || fail "uninstall left the provider registry behind"
[[ -f "$LEGACY_REGISTRY" ]] || fail "providers uninstall removed the registry owned by Claudex"

# A failed install leaves the unrelated retired registry untouched.
rm -f "$CLAUDEX_BIN"
print '{truncated' > "$HOME/.config/providers/state.json"
rc=0
install >/dev/null 2>&1 || rc=$?
(( rc != 0 )) || fail "install reported success despite a failed state migration"
[[ -f "$LEGACY_REGISTRY" ]] \
    || fail "a failed install destroyed the retired registry"
rm -f "$HOME/.config/providers/state.json"

install
[[ ! -e "$LEGACY_REGISTRY" ]] || fail "install left the stale retired registry behind"

# A stale retired registry is reclaimed on a later update.
cp "$ROOT/files/claudex-profiles.json" "$LEGACY_REGISTRY"
update
[[ ! -e "$LEGACY_REGISTRY" ]] || fail "update orphaned a stale retired registry"

uninstall
[[ ! -e "$REGISTRY" ]] || fail "uninstall left the provider registry behind"

echo "providers lifecycle tests passed"
