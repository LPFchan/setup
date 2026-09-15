#!/usr/bin/env zsh
set -euo pipefail
ROOT=${0:A:h:h}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
export AUTH_BIN="$HOME/.local/bin/auth"
export AUTH_SOURCE="$ROOT/files/auth"
mkdir -p "$XDG_STATE_HOME"

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/auth.sh"

install
[[ -x "$AUTH_BIN" ]]
[[ -f "$XDG_STATE_HOME/setup/auth.needs-login" ]]
status >/dev/null

mkdir -p "$HOME/.local/share/lost-plus"
print '{"version":1,"mode":"global","tokens":{"*":"secret"}}' \
    > "$HOME/.local/share/lost-plus/auth.json"
chmod 600 "$HOME/.local/share/lost-plus/auth.json"
update
status >/dev/null
[[ ! -e "$XDG_STATE_HOME/setup/auth.needs-login" ]]

uninstall
[[ ! -e "$AUTH_BIN" ]]
[[ -f "$HOME/.local/share/lost-plus/auth.json" ]]
echo "auth lifecycle tests passed"
