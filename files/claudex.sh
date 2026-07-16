#!/usr/bin/env bash
# setup-module: claudex
# setup-type: script
#
# Installs the claudex binary (StringKe/claudex) and seeds a `codex` profile
# into the canonical global config (~/.config/claudex/config.toml) wired to the
# ChatGPT/codex OAuth backend, so `claudex run codex` launches Claude Code
# through the codex subscription from any directory. The ai-menu `claudex` entry
# calls exactly that with an explicit --config so it is CWD-independent (a
# CWD-local ~/claudex.toml would otherwise shadow the global from $HOME and its
# subdirectories).
#
# The profile is seeded once (idempotent, matched by name) and its model mapping
# is enforced/repaired through claudex's own `config set` dot-paths. We do NOT
# wrap it in a setup-managed comment block: claudex strips all comments whenever
# it rewrites the file (any `config set`), which would orphan the markers and
# append a duplicate profile on every update. Presence + index therefore come
# from an anchored scan of the real `[[profiles]]` tables instead.

[[ "$(type -t git_clone_if_missing)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/../lib/script-helpers.sh"

MODULE="claudex"
BIN="$HOME/.local/bin/claudex"
GLOBAL_CONFIG="$HOME/.config/claudex/config.toml"
INSTALL_URL="https://raw.githubusercontent.com/StringKe/claudex/main/install.sh"

# Codex subscription model mapping. These drift over time (gpt-5.3-codex ->
# gpt-5.6-*); bump them here and `setup update` re-applies via `config set`.
CODEX_DEFAULT_MODEL="gpt-5.6-sol"
CODEX_MODEL_HAIKU="gpt-5.6-luna"
CODEX_MODEL_SONNET="gpt-5.6-terra"
CODEX_MODEL_OPUS="gpt-5.6-sol"

# 0-based index of the real `codex` profile, matching claudex's dot-path
# indexing; empty when absent. Anchored on `^[[profiles]]` so the commented
# `# [[profiles]]` example in a fresh config is skipped; `^name = "codex"$`
# excludes `codex-sub`. idx starts at -1 so the first real header becomes 0.
_codex_profile_index() {
    [[ -f "$GLOBAL_CONFIG" ]] || return 0
    awk 'BEGIN{idx=-1}
         /^\[\[profiles\]\]/ {idx++; next}
         /^name = "codex"$/  {print idx; exit}' "$GLOBAL_CONFIG"
}

_ensure_config() {
    mkdir -p "$(dirname "$GLOBAL_CONFIG")"
    [[ -f "$GLOBAL_CONFIG" ]] && return 0
    cat > "$GLOBAL_CONFIG" <<'EOF'
# Claudex configuration. The `codex` profile below is managed by the claudex
# setup module (LPFchan/setup); its model mapping is re-applied on `setup update`.
proxy_port = 13456
proxy_host = "127.0.0.1"
log_level = "info"

[model_aliases]

[router]
enabled = false
EOF
}

# Append the full codex profile once. It must be schema-complete — a profile
# missing a required field (e.g. default_model) makes the WHOLE config
# unparseable, so this mirrors the working reference profile field-for-field,
# with all scalars before the `[profiles.*]` sub-tables.
_seed_profile() {
    [[ -n "$(_codex_profile_index)" ]] && return 0
    cat >> "$GLOBAL_CONFIG" <<EOF

[[profiles]]
name = "codex"
provider_type = "OpenAIResponses"
base_url = "https://chatgpt.com/backend-api/codex"
api_key = ""
default_model = "$CODEX_DEFAULT_MODEL"
backup_providers = []
priority = 100
enabled = true
auth_type = "oauth"
oauth_provider = "chatgpt"
strip_params = "Auto"

[profiles.custom_headers]

[profiles.extra_env]

[profiles.models]
haiku = "$CODEX_MODEL_HAIKU"
sonnet = "$CODEX_MODEL_SONNET"
opus = "$CODEX_MODEL_OPUS"

[profiles.query_params]
EOF
}

_enforce_models() {
    local idx
    idx=$(_codex_profile_index)
    [[ -n "$idx" ]] || { echo "claudex: codex profile missing after seed — cannot enforce models" >&2; return 1; }
    "$BIN" config set --config "$GLOBAL_CONFIG" "profiles.$idx.default_model" "$CODEX_DEFAULT_MODEL" >/dev/null || return 1
    "$BIN" config set --config "$GLOBAL_CONFIG" "profiles.$idx.models.haiku"  "$CODEX_MODEL_HAIKU"  >/dev/null || return 1
    "$BIN" config set --config "$GLOBAL_CONFIG" "profiles.$idx.models.sonnet" "$CODEX_MODEL_SONNET" >/dev/null || return 1
    "$BIN" config set --config "$GLOBAL_CONFIG" "profiles.$idx.models.opus"   "$CODEX_MODEL_OPUS"   >/dev/null || return 1
    "$BIN" config set --config "$GLOBAL_CONFIG" "profiles.$idx.enabled" true >/dev/null || return 1
}

# True when the on-disk codex profile already matches the desired mapping.
_models_current() {
    local idx d h s o
    idx=$(_codex_profile_index)
    [[ -n "$idx" ]] || return 1
    d=$("$BIN" config get --config "$GLOBAL_CONFIG" "profiles.$idx.default_model" 2>/dev/null)
    h=$("$BIN" config get --config "$GLOBAL_CONFIG" "profiles.$idx.models.haiku"  2>/dev/null)
    s=$("$BIN" config get --config "$GLOBAL_CONFIG" "profiles.$idx.models.sonnet" 2>/dev/null)
    o=$("$BIN" config get --config "$GLOBAL_CONFIG" "profiles.$idx.models.opus"   2>/dev/null)
    [[ "$d" == "$CODEX_DEFAULT_MODEL" && "$h" == "$CODEX_MODEL_HAIKU" \
       && "$s" == "$CODEX_MODEL_SONNET" && "$o" == "$CODEX_MODEL_OPUS" ]]
}

# Reuses existing codex-cli OAuth creds — autonomous, no browser prompt when
# already logged in. claudex stores the token in the kernel session keyring on
# Linux; some login shells start without one, so wrap the login in a fresh
# anonymous session keyring there. macOS uses the Keychain and has no keyctl.
_auth_login() {
    local -a login=("$BIN" auth login --config "$GLOBAL_CONFIG" chatgpt --profile codex)
    if [[ "$(uname -s)" == "Linux" ]] && command -v keyctl >/dev/null 2>&1; then
        keyctl session - "${login[@]}"
    else
        "${login[@]}"
    fi
}

install() {
    if [[ ! -x "$BIN" ]]; then
        curl -fsSL "$INSTALL_URL" | bash
    else
        echo "claudex already installed: $("$BIN" --version 2>/dev/null | head -1)"
    fi
    _ensure_config
    _seed_profile
    _enforce_models || echo "claudex: model enforcement failed — check '$GLOBAL_CONFIG'" >&2
    if ! _auth_login; then
        echo "claudex: auth login did not complete. Run it once codex creds exist:" >&2
        echo "  claudex auth login --config \"$GLOBAL_CONFIG\" chatgpt --profile codex" >&2
    fi
    _record_state
    echo "claudex: installed -> $BIN (codex profile in $GLOBAL_CONFIG)"
}

status() {
    if [[ ! -x "$BIN" ]]; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local idx cur
    idx=$(_codex_profile_index)
    if [[ -z "$idx" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "no-profile" "$CODEX_DEFAULT_MODEL" "$GLOBAL_CONFIG"
        record_script_state "$MODULE" "models" "no-profile" "$CODEX_DEFAULT_MODEL"
        return 1
    fi
    if _models_current; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "$CODEX_DEFAULT_MODEL" "$CODEX_DEFAULT_MODEL" "$GLOBAL_CONFIG"
        record_script_state "$MODULE" "models" "$CODEX_DEFAULT_MODEL" "$CODEX_DEFAULT_MODEL"
        return 0
    fi
    cur=$("$BIN" config get --config "$GLOBAL_CONFIG" "profiles.$idx.default_model" 2>/dev/null)
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${cur:-unknown}" "$CODEX_DEFAULT_MODEL" "$GLOBAL_CONFIG"
    record_script_state "$MODULE" "models" "${cur:-unknown}" "$CODEX_DEFAULT_MODEL"
    return 1
}

update() {
    if [[ -x "$BIN" ]]; then
        "$BIN" update >/dev/null 2>&1 || curl -fsSL "$INSTALL_URL" | bash
    else
        curl -fsSL "$INSTALL_URL" | bash
    fi
    _ensure_config
    _seed_profile
    _enforce_models || echo "claudex: model enforcement failed — check '$GLOBAL_CONFIG'" >&2
    _record_state
    echo "claudex: updated -> $BIN"
}

uninstall() {
    if [[ -x "$BIN" ]]; then
        "$BIN" profile remove --config "$GLOBAL_CONFIG" codex >/dev/null 2>&1 \
            || echo "claudex: could not remove codex profile — edit '$GLOBAL_CONFIG' manually if desired" >&2
    fi
    rm -f "$BIN"
    remove_script_state "$MODULE"
    echo "claudex: uninstalled (binary + codex profile removed)"
}

_record_state() {
    record_script_state "$MODULE" "models" "$CODEX_DEFAULT_MODEL" "$CODEX_DEFAULT_MODEL"
}
