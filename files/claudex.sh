#!/usr/bin/env zsh
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
# Freshness follows the block-module convention (see zsh-basics/ssh-aliases):
# drift is detected from a sha256 of the *desired profile block* (`_profile_block`,
# the module's source of truth incl. the CODEX_* model vars) — NOT of this whole
# file, so editing a comment here does not mark every machine outdated, and NOT
# of the installed profile's text, so claudex's comment-stripping reformat on any
# `config set` never registers as drift. A cheap live presence check
# (`_codex_profile_index`) additionally flags a profile that was removed, so a
# dropped codex profile self-heals on the next `setup update`.
#
# We do NOT wrap the profile in a setup-managed comment block: claudex strips all
# comments whenever it rewrites the file, which would orphan the markers and
# append a duplicate profile. Presence + index therefore come from an anchored
# scan of the real `[[profiles]]` tables instead.

(( ${+functions[git_clone_if_missing]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="claudex"
BIN="$HOME/.local/bin/claudex"
GLOBAL_CONFIG="$HOME/.config/claudex/config.toml"
INSTALL_URL="https://raw.githubusercontent.com/StringKe/claudex/main/install.sh"

# Codex subscription model mapping. These drift over time (gpt-5.3-codex ->
# gpt-5.6-*); bump them here and `setup update` re-applies (the hash below
# changes, so every machine reports outdated until re-seeded).
CODEX_DEFAULT_MODEL="gpt-5.6-sol"
CODEX_MODEL_HAIKU="gpt-5.6-luna"
CODEX_MODEL_SONNET="gpt-5.6-terra"
CODEX_MODEL_OPUS="gpt-5.6-sol"

# The desired codex profile, source of truth for both seeding and the drift
# hash. Schema-complete (a profile missing a required field such as default_model
# makes the WHOLE config unparseable); all scalars precede the `[profiles.*]`
# sub-tables. Mirrors the working reference profile field-for-field.
_profile_block() {
    cat <<EOF

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

_desired_hash() { _profile_block | setup_sha256_string; }

# Full baseline hash recorded at the last install/update, from script-state.tsv.
_recorded_hash() {
    local rt lr rr
    IFS=$'\t' read -r rt lr rr < <(script_state_for "$MODULE" 2>/dev/null) && printf '%s' "$lr"
}

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
# setup module (LPFchan/setup); it is re-seeded from source on `setup update`.
proxy_port = 13456
proxy_host = "127.0.0.1"
log_level = "info"

[model_aliases]

[router]
enabled = false
EOF
}

# Make the on-disk codex profile exactly the desired block: textually drop any
# existing codex `[[profiles]]` block (by index) plus an empty `profiles = []`
# placeholder a prior claudex rewrite may have left, then append fresh. Every
# other profile and all surrounding content is preserved verbatim. This stays
# purely textual on purpose — invoking claudex's own `profile remove` here
# re-serializes the file and, when codex is the only profile, writes
# `profiles = []`, which then collides with our appended `[[profiles]]` table.
_apply_profile() {
    local idx tmp
    idx=$(_codex_profile_index)
    tmp=$(mktemp)
    awk -v target="${idx:--1}" '
        BEGIN { pc = -1 }
        /^profiles[[:space:]]*=[[:space:]]*\[\]/ { next }   # empty placeholder from a claudex rewrite
        /^\[\[profiles\]\]/ {
            pc++
            if (pc == target) { skip = 1; next }            # start of the codex block
            if (skip) skip = 0                              # a later profile ends it
        }
        skip && /^\[[^[]/ && $0 !~ /^\[profiles\./ { skip = 0 }   # a non-profiles table ends it
        skip { next }
        { print }
    ' "$GLOBAL_CONFIG" > "$tmp"
    mv "$tmp" "$GLOBAL_CONFIG"
    _profile_block >> "$GLOBAL_CONFIG"
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
    _apply_profile
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
    local idx desired recorded
    idx=$(_codex_profile_index)
    # Binary present but the module was never set up here (no profile, no state):
    # report as a new module to opt into, not something to auto-seed.
    if [[ -z "$idx" ]] && ! is_script_installed "$MODULE"; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    desired=$(_desired_hash)
    if [[ -z "$idx" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "no-profile" "${desired:0:7}" "$GLOBAL_CONFIG"
        record_script_state "$MODULE" "profile" "no-profile" "$desired"
        return 1
    fi
    recorded=$(_recorded_hash)
    if [[ "$recorded" == "$desired" ]]; then
        printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "current" "${recorded:0:7}" "${desired:0:7}" "$GLOBAL_CONFIG"
        record_script_state "$MODULE" "profile" "$desired" "$desired"
        return 0
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' "$MODULE" "outdated" "${recorded:0:7}" "${desired:0:7}" "$GLOBAL_CONFIG"
    record_script_state "$MODULE" "profile" "${recorded:-none}" "$desired"
    return 1
}

update() {
    if [[ -x "$BIN" ]]; then
        "$BIN" update >/dev/null 2>&1 || curl -fsSL "$INSTALL_URL" | bash
    else
        curl -fsSL "$INSTALL_URL" | bash
    fi
    _ensure_config
    _apply_profile
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
    local h
    h=$(_desired_hash)
    record_script_state "$MODULE" "profile" "$h" "$h"
}
