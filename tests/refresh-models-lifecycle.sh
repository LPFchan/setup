#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export REFRESH_MODELS_BIN="$HOME/.local/bin/refresh-models"
export CLAUDEX_BIN="$HOME/.local/bin/claudex"
export CLAUDEX_REGISTRY="$HOME/.config/claudex/managed-profiles.json"
export CLAUDEX_CONFIG="$HOME/.config/claudex/config.toml"
export CLAUDEX_AUTH_JSON="$HOME/.local/share/opencode/auth.json"
export REFRESH_MODELS_SOURCE="$ROOT/files/refresh-models"
export CLAUDEX_REGISTRY_SOURCE="$ROOT/files/claudex-profiles.json"
mkdir -p "$XDG_STATE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/refresh-models.sh"

expect_status() {
    local expected_rc="$1" expected_word="$2" output rc=0
    output=$(status) || rc=$?
    [[ "$rc" == "$expected_rc" ]] || fail "status returned $rc, expected $expected_rc: $output"
    [[ "$output" == *"$expected_word"* ]] || fail "status omitted $expected_word: $output"
}

mkdir -p "${BIN:h}"
cp "$ROOT/files/refresh-models" "$BIN"
chmod +x "$BIN"
expect_status 1 outdated

mkdir -p "$HOME/.config/opencode"
print '{"servers":{"commandcode":{"enabled":false}}}' \
    > "$HOME/.config/opencode/refresh-models.json"
install
[[ -x "$BIN" ]] || fail "standalone install omitted the launcher"
[[ -f "$REGISTRY" ]] || fail "standalone install omitted the shared registry"
[[ -f "$HOME/.config/opencode/refresh-models-state.json" ]] \
    || fail "install did not migrate provider enablement state"
[[ ! -e "$HOME/.config/opencode/refresh-models.json" ]] \
    || fail "install kept the obsolete provider registry"
grep -q '"enabled": false' "$HOME/.config/opencode/refresh-models-state.json" \
    || fail "install lost the legacy provider enablement state"
expect_status 0 current

print '# drift' >> "$BIN"
expect_status 1 outdated
update
expect_status 0 current

mkdir -p "${CLAUDEX_BIN:h}"
cp "$ROOT/files/claudex" "$CLAUDEX_BIN"
chmod +x "$CLAUDEX_BIN"
update
grep -q 'name = "commandcode"' "$CLAUDEX_CONFIG" \
    || fail "refresh-models did not apply the shared registry to co-installed Claudex"
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
uninstall
[[ -f "$REGISTRY" ]] || fail "refresh-models removed a registry still used by Claudex"

rm -f "$CLAUDEX_BIN"
install
uninstall
[[ ! -e "$REGISTRY" ]] || fail "last registry consumer left an orphaned registry"

echo "refresh-models lifecycle tests passed"
