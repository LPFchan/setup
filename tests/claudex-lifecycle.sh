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
export PROVIDERS_BIN="$HOME/.local/bin/providers"
export REFRESH_MODELS_BIN="$HOME/.local/bin/refresh-models"
export CLAUDEX_LAUNCHER_SOURCE="$ROOT/files/claudex"
export PROVIDER_REGISTRY_SOURCE="$ROOT/files/provider-registry.json"
export CLAUDEX_RELEASE_TAG="v0.2.4-fork.5"
mkdir -p "${CLAUDEX_BIN:h}" "${CLAUDEX_CORE:h}" "${CLAUDEX_REGISTRY:h}" "$XDG_STATE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/claudex.sh"

CLAUDEX_RELEASE_TAG=""
curl() { print '{"tag_name":"v9.8.7-fork.6"}'; }
[[ "$(_resolve_release_tag)" == "v9.8.7-fork.6" ]] || fail "latest GitHub tag was not resolved"
curl() { print '{"assets":[]}'; }
if _resolve_release_tag >/dev/null 2>&1; then
    fail "malformed GitHub release metadata was accepted"
fi
unfunction curl
CLAUDEX_RELEASE_TAG="v0.2.4-fork.5"

TEST_RELEASE_DIR="$TEST_TMP/release"
TEST_RELEASE_ARCHIVE="$TEST_TMP/claudex.tar.gz"
mkdir -p "$TEST_RELEASE_DIR"
print '#!/bin/sh\necho claudex 0.2.4-fork.5' > "$TEST_RELEASE_DIR/claudex"
chmod +x "$TEST_RELEASE_DIR/claudex"
tar czf "$TEST_RELEASE_ARCHIVE" -C "$TEST_RELEASE_DIR" claudex
TEST_RELEASE_DIGEST=$(setup_sha256_string < "$TEST_RELEASE_ARCHIVE")
TEST_RELEASE_ASSET="claudex-$CLAUDEX_RELEASE_TAG-$(_detect_target).tar.gz"
curl() {
    local destination=""
    while (( $# )); do
        if [[ "$1" == -o ]]; then destination="$2"; shift 2; else shift; fi
    done
    if [[ -n "$destination" ]]; then
        cp "$TEST_RELEASE_ARCHIVE" "$destination"
    else
        print "{\"assets\":[{\"name\":\"$TEST_RELEASE_ASSET\",\"digest\":\"sha256:$TEST_RELEASE_DIGEST\"}]}"
    fi
}
_install_fork_core "$CLAUDEX_RELEASE_TAG"
[[ "$(_installed_version)" == "0.2.4-fork.5" ]] || fail "digest-verified release was not installed"
core_digest=$(setup_sha256_string < "$CORE")
TEST_RELEASE_DIGEST="$(printf '0%.0s' {1..64})"
if _install_fork_core "$CLAUDEX_RELEASE_TAG" >/dev/null 2>&1; then
    fail "release archive with a mismatched digest was installed"
fi
[[ "$(setup_sha256_string < "$CORE")" == "$core_digest" ]] || fail "digest failure replaced the installed core"
unfunction curl

install_surfaces() {
    cp "$ROOT/files/claudex" "$BIN"
    chmod +x "$BIN"
    cp "$ROOT/files/provider-registry.json" "$REGISTRY"
    cat > "$CORE" <<'EOF'
#!/bin/sh
echo 'claudex 0.2.4-fork.5'
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
staged=$(mktemp -d)
_stage_assets "$staged"
[[ "$(_desired_hash_from "$staged" "v0.2.4-fork.5")" != "$(_desired_hash_from "$staged" "v0.2.4-fork.6")" ]] \
    || fail "resolved Claudex tag does not participate in desired state"
rm -rf "$staged"
record_script_state "$MODULE" "profile" "$hash" "$hash"
expect_status 0 current
IFS=$'\t' read -r ref_type _ < <(script_state_for "$MODULE")
[[ "$ref_type" == "release:v0.2.4-fork.5" ]] || fail "readable Claudex release was not recorded"

CLAUDEX_RELEASE_TAG="v0.2.4-fork.6"
expect_status 1 outdated
CLAUDEX_RELEASE_TAG="v0.2.4-fork.5"
expect_status 0 current

CLAUDEX_RELEASE_TAG=""
curl() { return 22; }
expect_status 0 unknown
unfunction curl
CLAUDEX_RELEASE_TAG="v0.2.4-fork.5"

print '# drift' >> "$BIN"
expect_status 1 outdated
cp "$ROOT/files/claudex" "$BIN"
chmod +x "$BIN"

print ' ' >> "$REGISTRY"
expect_status 1 outdated
cp "$ROOT/files/provider-registry.json" "$REGISTRY"

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

# providers keeps its own copy under ~/.config/providers now, so it is no
# longer a co-owner of this path and must not protect it from removal.
install_surfaces
mkdir -p "${PROVIDERS_BIN:h}"
print '#!/bin/sh' > "$PROVIDERS_BIN"
chmod +x "$PROVIDERS_BIN"
uninstall
[[ ! -f "$REGISTRY" ]] || fail "claudex orphaned a registry no other module owns"

# refresh-models is the last co-owner, so its presence still protects it.
install_surfaces
mkdir -p "${REFRESH_MODELS_BIN:h}"
print '#!/bin/sh' > "$REFRESH_MODELS_BIN"
chmod +x "$REFRESH_MODELS_BIN"
uninstall
[[ -f "$REGISTRY" ]] || fail "claudex removed a registry still used by refresh-models"
rm -f "$REFRESH_MODELS_BIN"

echo "claudex lifecycle tests passed"
