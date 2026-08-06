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
export OPENCODEX_REGISTRY_SOURCE="$ROOT/files/provider-registry.json"
export OPENCODEX_RELEASE_VERSION="2.7.42"
mkdir -p "${OPENCODEX_LAUNCHER:h}" "${OPENCODEX_REGISTRY:h}" "$XDG_STATE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/opencodex.sh"

OPENCODEX_RELEASE_VERSION=""
npm() { print '9.8.7'; }
[[ "$(_resolve_release_version)" == "9.8.7" ]] || fail "npm latest version was not resolved"
npm() { print 'undefined'; }
if _resolve_release_version >/dev/null 2>&1; then
    fail "empty npm latest metadata was accepted"
fi
unfunction npm
OPENCODEX_RELEASE_VERSION="2.7.42"

npm_args=""
npm() {
    npm_args="$*"
    local prefix=""
    while (( $# )); do
        if [[ "$1" == --prefix ]]; then prefix="$2"; shift 2; else shift; fi
    done
    mkdir -p "$prefix/node_modules/.bin"
    print '#!/bin/sh\necho opencodex 9.8.7' > "$prefix/node_modules/.bin/ocx"
    chmod +x "$prefix/node_modules/.bin/ocx"
}
_ensure_runtime "9.8.7"
[[ "$npm_args" == *"@bitkyc08/opencodex@9.8.7"* ]] || fail "resolved OpenCodex package was not installed"
[[ "$(_installed_version)" == "9.8.7" ]] || fail "resolved OpenCodex runtime version is wrong"
unfunction npm
rm -f "$OPENCODEX_BIN"
rm -rf "$OPENCODEX_ROOT"

install_surfaces() {
    cp "$ROOT/files/opencodex" "$BIN"
    chmod +x "$BIN"
    cp "$ROOT/files/provider-registry.json" "$REGISTRY"
    cat > "$OPENCODEX_BIN" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then echo 'opencodex 2.7.42'; fi
if [ "${1:-}" = service ] && [ "${2:-}" = status ] && [ -e "$HOME/.opencodex/service-stopped" ]; then exit 1; fi
EOF
    chmod +x "$OPENCODEX_BIN"
    _apply_all_providers
}

expect_status() {
    local expected_rc="$1" expected_word="$2" output rc=0
    output=$(status) || rc=$?
    [[ "$rc" == "$expected_rc" ]] || fail "status returned $rc, expected $expected_rc: $output"
    [[ "$output" == *"$expected_word"* ]] || fail "status omitted $expected_word: $output"
}

install_surfaces
hash=$(_desired_hash)
staged=$(mktemp -d)
_stage_assets "$staged"
[[ "$(_desired_hash_from "$staged" "2.7.42")" != "$(_desired_hash_from "$staged" "2.7.43")" ]] \
    || fail "resolved OpenCodex version does not participate in desired state"
rm -rf "$staged"
record_script_state "$MODULE" "profile" "$hash" "$hash"
expect_status 0 current
IFS=$'\t' read -r ref_type _ < <(script_state_for "$MODULE")
[[ "$ref_type" == "release:2.7.42" ]] || fail "readable OpenCodex release was not recorded"

OPENCODEX_RELEASE_VERSION="2.7.43"
expect_status 1 outdated
OPENCODEX_RELEASE_VERSION="2.7.42"
expect_status 0 current

OPENCODEX_RELEASE_VERSION=""
npm() { return 1; }
expect_status 0 unknown
unfunction npm
OPENCODEX_RELEASE_VERSION="2.7.42"

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
cp "$ROOT/files/provider-registry.json" "$shared_registry"
(
    export CLAUDEX_REGISTRY="$shared_registry"
    export PROVIDERS_BIN="$HOME/.local/bin/missing-providers"
    source "$ROOT/files/claudex.sh"
    uninstall >/dev/null
)
[[ -f "$REGISTRY" ]] || fail "claudex uninstall removed opencodex's independent snapshot"

providers_registry="$HOME/.config/providers/registry.json"
mkdir -p "${providers_registry:h}"
cp "$ROOT/files/provider-registry.json" "$providers_registry"
(
    export PROVIDERS_REGISTRY="$providers_registry"
    source "$ROOT/files/providers.sh"
    uninstall >/dev/null
)
[[ -f "$REGISTRY" ]] || fail "providers uninstall removed opencodex's independent snapshot"
[[ ! -e "$providers_registry" ]] || fail "providers uninstall left its own snapshot"

uninstall
[[ ! -e "$REGISTRY" ]] || fail "opencodex uninstall left its provider snapshot"
[[ ! -e "$BIN" && ! -e "$OPENCODEX_ROOT" ]] || fail "opencodex uninstall left runtime files"

echo "opencodex lifecycle tests passed"
