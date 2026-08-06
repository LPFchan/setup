#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export CLAUDEX_BIN="$ROOT/files/claudex"
export CLAUDEX_CORE="$TEST_TMP/claudex-core"
export CLAUDEX_CONFIG="$HOME/.config/claudex/config.toml"
export CLAUDEX_REGISTRY="$ROOT/files/provider-registry.json"
export CLAUDEX_AUTH_JSON="$HOME/.local/share/opencode/auth.json"
export CLAUDEX_LAUNCHER_SOURCE="$ROOT/files/claudex"
export PROVIDER_REGISTRY_SOURCE="$ROOT/files/provider-registry.json"
export CLAUDEX_RELEASE_TAG="v0.2.4-fork.5"
mkdir -p "$HOME/.config/claudex" "$HOME/.local/share/opencode" "$XDG_STATE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/lib/script-helpers.sh"

cat > "$CLAUDEX_CONFIG" <<'EOF'
proxy_port = 13456
proxy_host = "127.0.0.1"
log_level = "info"

[model_aliases]

[router]
enabled = false

[[profiles]]
name = "foreign"
provider_type = "OpenAICompatible"
base_url = "https://example.invalid/v1"
api_key = "foreign-key"
default_model = "foreign-model"
enabled = true
priority = 50

[profiles.models]
haiku = "foreign-haiku"
EOF

cat > "$CLAUDEX_AUTH_JSON" <<'EOF'
{"commandcode": {"type": "api", "key": "user_testkey123"}}
EOF

source "$ROOT/files/claudex.sh"
_apply_all_profiles

grep -q '^name = "commandcode"$' "$CLAUDEX_CONFIG" || fail "commandcode profile missing"
grep -q '^api_key = "user_testkey123"$' "$CLAUDEX_CONFIG" || fail "local API key was not resolved"
grep -q '^name = "codex"$' "$CLAUDEX_CONFIG" || fail "codex profile missing"
grep -q '^name = "foreign"$' "$CLAUDEX_CONFIG" || fail "foreign profile was dropped"
grep -q '^api_key = "foreign-key"$' "$CLAUDEX_CONFIG" || fail "foreign profile changed"

cp "$CLAUDEX_CONFIG" "$TEST_TMP/config.first"
_apply_all_profiles
cmp -s "$CLAUDEX_CONFIG" "$TEST_TMP/config.first" || fail "registry rendering was not idempotent"

hash_before=$(_desired_hash)
cat > "$CLAUDEX_AUTH_JSON" <<'EOF'
{"commandcode": {"type": "api", "key": "user_rotated456"}}
EOF
hash_after=$(_desired_hash)
[[ "$hash_before" == "$hash_after" ]] || fail "credentials participate in desired-state hash"
_apply_all_profiles
grep -q '^api_key = "user_rotated456"$' "$CLAUDEX_CONFIG" || fail "rotated key was not applied"
_profiles_current || fail "rendered profiles reported drift"

rm -f "$CLAUDEX_AUTH_JSON"
_apply_all_profiles
grep -q '^api_key = ""$' "$CLAUDEX_CONFIG" || fail "missing local key did not render empty"
grep -q '^auth_type = "api-key"$' "$CLAUDEX_CONFIG" || fail "API auth type is invalid"

# The former layout placed the third-party binary at the launcher path. A
# binary matching the resolved release migrates to libexec without a download.
BIN="$TEST_TMP/old-claudex"
CORE="$TEST_TMP/libexec/claudex-core"
cat > "$BIN" <<'EOF'
#!/bin/sh
echo 'claudex 0.2.4-fork.5'
EOF
chmod +x "$BIN"
_ensure_core "$CLAUDEX_RELEASE_TAG"
[[ -x "$CORE" ]] || fail "old binary was not migrated to libexec"
[[ "$(_installed_version)" == "0.2.4-fork.5" ]] || fail "migrated core version is wrong"

echo "claudex registry rendering tests passed"
