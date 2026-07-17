#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" STATE_DIR="$TMP/state/setup" SETUP_SOURCE_ONLY=1
mkdir -p "$STATE_DIR"
# shellcheck disable=SC1091
source "$ROOT/bin/setup"

curl() {
    local out
    while (($#)); do [[ "$1" == -o ]] && { out="$2"; break; }; shift; done
    printf '# module\ttarget\tmode\tsource\nnew\t~/new\t0755\tx\n' > "$out"
}
real_mv=$(command -v mv)
FORCED_TMP="$TMP/fetched"
mv() { [[ "$1" == "$FORCED_TMP" ]] && return 17; "$real_mv" "$@"; }
mktemp() { : > "$FORCED_TMP"; printf '%s\n' "$FORCED_TMP"; }

# Absent cache remains absent and callers stop.
rm -f "$MANIFEST_FILE"
if fetch_manifest >/dev/null 2>&1; then echo "mv failure returned success" >&2; exit 1; fi
[[ ! -e "$MANIFEST_FILE" ]] || { echo "mv failure created manifest" >&2; exit 1; }
[[ ! -e "$FORCED_TMP" ]] || { echo "mv failure leaked temp" >&2; exit 1; }
if cmd_list >/dev/null 2>&1; then echo "caller proceeded after mv failure" >&2; exit 1; fi

# Existing cache is preserved byte-for-byte on replacement failure.
printf '# module\ttarget\tmode\tsource\nold\t~/old\t0755\tx\n' > "$MANIFEST_FILE"
before=$(cat "$MANIFEST_FILE")
if fetch_manifest >/dev/null 2>&1; then echo "existing-cache mv failure returned success" >&2; exit 1; fi
[[ $(cat "$MANIFEST_FILE") == "$before" ]] || { echo "mv failure damaged old cache" >&2; exit 1; }
[[ ! -e "$FORCED_TMP" ]] || { echo "existing-cache failure leaked temp" >&2; exit 1; }

echo "manifest atomicity tests passed"
