#!/usr/bin/env zsh
# claudex commandcode profile: apply preserves foreign profiles, inlines the
# refresh-models-managed API key, is idempotent, and degrades gracefully when
# auth.json is absent. The drift hash must NOT cover the key (rotation noise).
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
mkdir -p "$HOME/.local/share/opencode" "$XDG_STATE_HOME"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# shellcheck disable=SC1091
source "$ROOT/lib/script-helpers.sh"

# --- fixture: a config with a hand-made (foreign) profile --------------------
mkdir -p "$HOME/.config/claudex"
cat > "$HOME/.config/claudex/config.toml" <<'EOF'
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

# --- fixture: refresh-models auth store --------------------------------------
cat > "$HOME/.local/share/opencode/auth.json" <<'EOF'
{"commandcode": {"type": "api", "key": "user_testkey123"}}
EOF

# Load the module functions without running install/update (curl, keyring).
# shellcheck disable=SC1091
source "$ROOT/files/claudex.sh"

# --- apply: commandcode block appears with key inlined, foreign untouched ----
_apply_all_profiles

rtk grep -q '^name = "commandcode"$' "$HOME/.config/claudex/config.toml" \
    || fail "commandcode profile was not appended"
rtk grep -q '^api_key = "user_testkey123"$' "$HOME/.config/claudex/config.toml" \
    || fail "commandcode api_key was not inlined from auth.json"
rtk grep -q '^name = "codex"$' "$HOME/.config/claudex/config.toml" \
    || fail "codex profile was not appended"
rtk grep -q '^name = "foreign"$' "$HOME/.config/claudex/config.toml" \
    || fail "foreign profile was dropped"
rtk grep -q '^api_key = "foreign-key"$' "$HOME/.config/claudex/config.toml" \
    || fail "foreign profile content was modified"

# exactly one of each managed profile (rtk grep -c is a report, not a count)
_count() { awk -v pat="$1" '$0 ~ pat {n++} END {print n+0}' "$2"; }
[[ $(_count '^name = "commandcode"$' "$HOME/.config/claudex/config.toml") == 1 ]] \
    || fail "commandcode profile appended more than once"
[[ $(_count '^name = "codex"$' "$HOME/.config/claudex/config.toml") == 1 ]] \
    || fail "codex profile appended more than once"

# --- idempotent: second apply changes nothing --------------------------------
cp "$HOME/.config/claudex/config.toml" "$TEST_TMP/config.after-first"
_apply_all_profiles
cmp -s "$HOME/.config/claudex/config.toml" "$TEST_TMP/config.after-first" \
    || fail "second _apply_all_profiles was not idempotent"

# --- key rotation rewrites the key but does not move the drift hash ----------
hash_before=$(_desired_hash)
cat > "$HOME/.local/share/opencode/auth.json" <<'EOF'
{"commandcode": {"type": "api", "key": "user_rotated456"}}
EOF
hash_after=$(_desired_hash)
[[ "$hash_before" == "$hash_after" ]] \
    || fail "drift hash covers the api_key — key rotation would flag every machine outdated"
_apply_all_profiles
rtk grep -q '^api_key = "user_rotated456"$' "$HOME/.config/claudex/config.toml" \
    || fail "rotated key was not applied"

# --- missing auth.json: profile still seeds with an empty key ----------------
rm -f "$HOME/.local/share/opencode/auth.json"
[[ -z "$(_commandcode_api_key)" ]] \
    || fail "_commandcode_api_key should be empty when auth.json is missing"
_apply_all_profiles
rtk grep -q '^name = "commandcode"$' "$HOME/.config/claudex/config.toml" \
    || fail "commandcode profile missing after apply without auth.json"
rtk grep -q '^api_key = ""$' "$HOME/.config/claudex/config.toml" \
    || fail "commandcode api_key should be empty without auth.json"

# --- profile index: finds the right blocks, ignores comments -----------------
[[ "$(_profile_index codex)" == "1" ]] \
    || fail "_profile_index codex should be 1 (foreign is 0), got '$(_profile_index codex)'"
[[ -z "$(_profile_index nosuch)" ]] \
    || fail "_profile_index should be empty for an absent profile"

echo "claudex commandcode profile tests passed"
