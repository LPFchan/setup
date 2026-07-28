#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export CLAUDEX_BIN="$HOME/.local/bin/claudex"
export CLAUDEX_CORE="$HOME/.local/libexec/claudex-core"
export CLAUDEX_CONFIG="$HOME/.config/claudex/config.toml"
export CLAUDEX_REGISTRY="$HOME/.config/claudex/managed-profiles.json"
export CLAUDEX_AUTH_JSON="$HOME/.local/share/opencode/auth.json"
export CLAUDEX_LAUNCHER_SOURCE="$ROOT/files/claudex"
export CLAUDEX_REGISTRY_SOURCE="$ROOT/files/claudex-profiles.json"
mkdir -p "${CLAUDEX_BIN:h}" "${CLAUDEX_CORE:h}" "${CLAUDEX_REGISTRY:h}" "$XDG_STATE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/claudex.sh"

install_surfaces() {
    cp "$ROOT/files/claudex" "$BIN"
    chmod +x "$BIN"
    cp "$ROOT/files/claudex-profiles.json" "$REGISTRY"
    cat > "$CORE" <<'EOF'
#!/bin/sh
echo 'claudex 0.2.4-fork.2'
EOF
    chmod +x "$CORE"
    _apply_all_profiles
}

expect_status() {
    local expected_rc="$1" expected_word="$2" output rc=0
    output=$(status) || rc=$?
    [[ "$rc" == "$expected_rc" ]] || fail "status returned $rc, expected $expected_rc: $output"
    [[ "$output" == *"$expected_word"* ]] || fail "status omitted $expected_word: $output"
}

install_surfaces
hash=$(_desired_hash)
record_script_state "$MODULE" "profile" "$hash" "$hash"
expect_status 0 current

print '# drift' >> "$BIN"
expect_status 1 outdated
cp "$ROOT/files/claudex" "$BIN"
chmod +x "$BIN"

print ' ' >> "$REGISTRY"
expect_status 1 outdated
cp "$ROOT/files/claudex-profiles.json" "$REGISTRY"

rm -f "$CORE"
expect_status 1 outdated
install_surfaces

rm -f "$BIN"
expect_status 1 outdated
install_surfaces

rm -f "$REGISTRY"
expect_status 1 outdated

remove_script_state "$MODULE"
expect_status 2 uninstalled

echo "claudex lifecycle tests passed"
