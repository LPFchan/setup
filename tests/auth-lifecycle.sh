#!/usr/bin/env zsh
set -euo pipefail
ROOT=${0:A:h:h}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
export AUTH_BIN="$HOME/.local/bin/auth"
export AUTH_SOURCE="$ROOT/files/auth"
export LOST_AUTH_ORIGIN="http://127.0.0.1:1"
mkdir -p "$XDG_STATE_HOME"

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/auth.sh"

install
[[ -x "$AUTH_BIN" ]]
[[ -f "$XDG_STATE_HOME/setup/auth.needs-login" ]]
status >/dev/null

mkdir -p "$HOME/.local/share/lost-plus"
print '{"version":2,"origin":"http://127.0.0.1:1","account_sub":"42","session_state":"active","mode":"global","tokens":{"*":"secret"},"session":{"id":"dev_test","refresh_token":"refresh-secret","expires_at":9999999999},"active_scopes":["*"],"unavailable_scopes":[]}' \
    > "$HOME/.local/share/lost-plus/auth.json"
chmod 600 "$HOME/.local/share/lost-plus/auth.json"
update
status >/dev/null
[[ ! -e "$XDG_STATE_HOME/setup/auth.needs-login" ]]

uninstall
[[ ! -e "$AUTH_BIN" ]]
[[ -f "$HOME/.local/share/lost-plus/auth.json" ]]
echo "auth lifecycle tests passed"
