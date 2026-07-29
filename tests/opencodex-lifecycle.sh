#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export OPENCODEX_LAUNCHER="$HOME/.local/bin/opencodex"
export OPENCODEX_ROOT="$HOME/.local/libexec/opencodex"
export OPENCODEX_BIN="$HOME/.local/bin/ocx"
export OPENCODEX_CONFIG="$HOME/.opencodex/config.json"
export OPENCODEX_MANAGED="$HOME/.opencodex/setup-managed-providers.json"
export OPENCODEX_REGISTRY="$HOME/.config/opencodex/managed-profiles.json"
export OPENCODEX_AUTH_JSON="$HOME/.local/share/opencode/auth.json"
export OPENCODEX_LAUNCHER_SOURCE="$ROOT/files/opencodex"
export OPENCODEX_REGISTRY_SOURCE="$ROOT/files/claudex-profiles.json"
mkdir -p "${OPENCODEX_LAUNCHER:h}" "${OPENCODEX_REGISTRY:h}" "$XDG_STATE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/opencodex.sh"

install_surfaces() {
    cp "$ROOT/files/opencodex" "$BIN"
    chmod +x "$BIN"
    cp "$ROOT/files/claudex-profiles.json" "$REGISTRY"
    cat > "$OPENCODEX_BIN" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then echo 'opencodex 2.7.42'; fi
if [ "${1:-}" = service ] && [ "${2:-}" = status ] && [ -e "$HOME/.opencodex/service-stopped" ]; then exit 1; fi
EOF
    chmod +x "$OPENCODEX_BIN"
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

touch "$HOME/.opencodex/service-stopped"
expect_status 1 outdated
rm "$HOME/.opencodex/service-stopped"
expect_status 0 current

print '# drift' >> "$BIN"
expect_status 1 outdated
install_surfaces

rm -f "$OPENCODEX_BIN"
expect_status 1 outdated
install_surfaces

shared_registry="$HOME/.config/claudex/managed-profiles.json"
mkdir -p "${shared_registry:h}"
cp "$ROOT/files/claudex-profiles.json" "$shared_registry"
(
    export CLAUDEX_REGISTRY="$shared_registry"
    export REFRESH_MODELS_BIN="$HOME/.local/bin/missing-refresh-models"
    source "$ROOT/files/claudex.sh"
    uninstall >/dev/null
)
[[ -f "$REGISTRY" ]] || fail "claudex uninstall removed opencodex's independent snapshot"

cp "$ROOT/files/claudex-profiles.json" "$shared_registry"
(
    export CLAUDEX_REGISTRY="$shared_registry"
    export CLAUDEX_BIN="$HOME/.local/bin/missing-claudex"
    source "$ROOT/files/refresh-models.sh"
    uninstall >/dev/null
)
[[ -f "$REGISTRY" ]] || fail "refresh-models uninstall removed opencodex's independent snapshot"

uninstall
[[ ! -e "$REGISTRY" ]] || fail "opencodex uninstall left its provider snapshot"
[[ ! -e "$BIN" && ! -e "$OPENCODEX_ROOT" ]] || fail "opencodex uninstall left runtime files"

echo "opencodex lifecycle tests passed"
