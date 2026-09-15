#!/usr/bin/env zsh
set -euo pipefail
ROOT=${0:A:h:h}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
mkdir -p "$HOME/.local/bin" "$XDG_STATE_HOME/setup"
marker="$XDG_STATE_HOME/setup/auth.needs-login"
touch "$marker"

cat > "$HOME/.local/bin/auth" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$AUTH_LOG"
exit "${AUTH_RC:-0}"
EOF
chmod +x "$HOME/.local/bin/auth"

cat > "$TMP/driver" <<EOF
#!/usr/bin/env zsh
export HOME='$HOME' XDG_STATE_HOME='$XDG_STATE_HOME' STATE_DIR='$XDG_STATE_HOME/setup'
export SETUP_SOURCE_ONLY=1 PATH='/usr/bin:/bin'
source '$ROOT/bin/setup'
_post_auth_setup
EOF
chmod +x "$TMP/driver"

run_driver() {
    if [[ "$(uname -s)" == Darwin ]]; then
        script -q /dev/null "$TMP/driver"
    else
        script -qec "$TMP/driver" /dev/null
    fi
}

AUTH_LOG="$TMP/auth.log" AUTH_RC=7 run_driver >/dev/null 2>&1 || true
[[ -e "$marker" ]]
[[ $(cat "$TMP/auth.log") == $'status\nlogin' ]]

: > "$TMP/auth.log"
AUTH_LOG="$TMP/auth.log" AUTH_RC=0 run_driver >/dev/null 2>&1
[[ ! -e "$marker" ]]
[[ $(cat "$TMP/auth.log") == status ]]
echo "auth onboarding tests passed"
