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
# A login declined earlier in the same run is skipped once, then offered again.
touch "$marker" "$XDG_STATE_HOME/setup/auth.login-deferred"
: > "$TMP/auth.log"
AUTH_LOG="$TMP/auth.log" AUTH_RC=7 run_driver >/dev/null 2>&1
[[ -e "$marker" && ! -e "$XDG_STATE_HOME/setup/auth.login-deferred" ]]
[[ ! -s "$TMP/auth.log" ]]
AUTH_LOG="$TMP/auth.log" AUTH_RC=7 run_driver >/dev/null 2>&1 || true
[[ $(cat "$TMP/auth.log") == $'status\nlogin' ]]
# fleet's own login also stays quiet after a decline in the same run.
cat > "$TMP/fleet-driver" <<EOF
#!/usr/bin/env zsh
export HOME='$HOME' XDG_STATE_HOME='$XDG_STATE_HOME' PATH='/usr/bin:/bin'
source '$ROOT/files/fleet.sh'
_login_if_needed
EOF
chmod +x "$TMP/fleet-driver"
touch "$XDG_STATE_HOME/setup/auth.login-deferred"
: > "$TMP/auth.log"
if [[ "$(uname -s)" == Darwin ]]; then
    AUTH_LOG="$TMP/auth.log" AUTH_RC=7 script -q /dev/null "$TMP/fleet-driver" >/dev/null 2>&1
else
    AUTH_LOG="$TMP/auth.log" AUTH_RC=7 script -qec "$TMP/fleet-driver" /dev/null >/dev/null 2>&1
fi
[[ $(cat "$TMP/auth.log") == status ]]
echo "auth onboarding tests passed"
