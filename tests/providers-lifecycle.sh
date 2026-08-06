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
export PROVIDERS_AUTH_JSON="$HOME/.local/share/opencode/auth.json"
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
# A machine upgrading from the shared claudex copy hands it over to providers.
mkdir -p "${LEGACY_REGISTRY:h}"
cp "$ROOT/files/provider-registry.json" "$LEGACY_REGISTRY"
install
[[ -x "$BIN" ]] || fail "standalone install omitted the launcher"
[[ -f "$REGISTRY" ]] || fail "standalone install omitted the provider registry"
[[ ! -e "$LEGACY_REGISTRY" ]] || fail "install left the superseded shared registry behind"
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
cp "$ROOT/files/provider-registry.json" "$LEGACY_REGISTRY"
update
[[ -f "$LEGACY_REGISTRY" ]] || fail "providers took over a registry copy claudex still owns"
grep -q 'name = "commandcode"' "$CLAUDEX_CONFIG" \
    || fail "providers did not apply the shared registry to co-installed Claudex"
grep -q 'name = "codex"' "$CLAUDEX_CONFIG" \
    || fail "shared registry lost the Codex OAuth profile"
grep -q 'oauth_provider = "chatgpt"' "$CLAUDEX_CONFIG" \
    || fail "shared registry lost Codex OAuth importability"
grep -q 'name = "anthropic"' "$CLAUDEX_CONFIG" \
    || fail "shared registry lost the Anthropic OAuth profile"
python3 - "$CLAUDEX_CONFIG" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
match = re.search(r'\[\[profiles\]\]\nname = "anthropic"\n(?P<body>.*?)(?=\n\[\[profiles\]\]|\Z)', text, re.S)
assert match
body = match.group("body")
assert 'provider_type = "DirectAnthropic"' in body
assert 'oauth_provider = "claude"' in body
PY

# Claudex is retired: providers still hands it the registry, but a failure in
# unmaintained claudex code must not veto a maintained module's own update.
print '#!/usr/bin/env python3\nraise SystemExit(3)' > "$CLAUDEX_BIN"
chmod +x "$CLAUDEX_BIN"
print '# drift' >> "$BIN"
expect_status 1 outdated
update 2>"$TEST_TMP/claudex.err" \
    || fail "a failing retired claudex aborted the providers update"
expect_status 0 current
grep -q claudex "$TEST_TMP/claudex.err" \
    || fail "a failing claudex __apply was reported to nobody"
cp "$ROOT/files/claudex" "$CLAUDEX_BIN"
chmod +x "$CLAUDEX_BIN"

uninstall
[[ ! -e "$REGISTRY" ]] || fail "uninstall left the provider registry behind"
[[ -f "$LEGACY_REGISTRY" ]] || fail "providers uninstall removed the registry claudex owns"

# A failure between staging and the atomic swap leaves the old launcher
# installed, and the old launcher reads the legacy registry: it must survive.
rm -f "$CLAUDEX_BIN"
print '{truncated' > "$HOME/.config/providers/state.json"
rc=0
install >/dev/null 2>&1 || rc=$?
(( rc != 0 )) || fail "install reported success despite a failed state migration"
[[ -f "$LEGACY_REGISTRY" ]] \
    || fail "a failed install destroyed the registry the installed launcher reads"
rm -f "$HOME/.config/providers/state.json"

install
[[ ! -e "$LEGACY_REGISTRY" ]] || fail "install left the superseded shared registry behind"

# A legacy copy stranded on a machine that later loses claudex is reclaimed on
# the next update, not orphaned forever behind a first-install-only migration.
cp "$ROOT/files/provider-registry.json" "$LEGACY_REGISTRY"
update
[[ ! -e "$LEGACY_REGISTRY" ]] || fail "update orphaned a superseded shared registry"

uninstall
[[ ! -e "$REGISTRY" ]] || fail "uninstall left the provider registry behind"

echo "providers lifecycle tests passed"
