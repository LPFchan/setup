#!/usr/bin/env zsh
set -euo pipefail
ROOT=${0:A:h:h}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
export PASSAGE_BIN="$HOME/.local/bin/passage"
export PASSAGE_SOURCE="$ROOT/files/passage"
mkdir -p "$XDG_STATE_HOME"

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/passage.sh"

install
[[ -x "$PASSAGE_BIN" ]]
status >/dev/null
"$PASSAGE_BIN" --help >/dev/null

update
status >/dev/null

uninstall
[[ ! -e "$PASSAGE_BIN" ]]
echo "passage lifecycle tests passed"
