#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" STATE_DIR="$TMP/state/setup"
mkdir -p "$HOME/.local/bin" "$STATE_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/script-helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/files/fzf-multicolumn.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$BIN" <<'EOF'
#!/bin/sh
case "$1" in --version) echo old ;; --help) echo '--grid=COLS' ;; esac
EOF
chmod +x "$BIN"
_has_span_capability "$BIN" && fail "pre-capable binary passed capability floor"

_download_release() {
    cat > "$BIN.new" <<'EOF'
#!/bin/sh
case "$1" in --version) echo new ;; --help) echo '--grid-span-prefix=STR' ;; esac
EOF
    chmod +x "$BIN.new"
    rm -f "$BIN"
    mv "$BIN.new" "$BIN"
}
_record_state() { :; }
install >/dev/null
_has_span_capability "$BIN" || fail "install did not upgrade pre-capable managed target"

# Regression: grep -q used to close the pipe early and make a capable binary
# fail under pipefail/SIGPIPE when --help was large. The probe must consume all
# output before matching.
cat > "$BIN" <<'EOF'
#!/bin/sh
if [ "$1" = --help ]; then
    echo '--grid-span-prefix=STR'
    i=0; while [ "$i" -lt 20000 ]; do echo "help filler $i abcdefghijklmnopqrstuvwxyz"; i=$((i+1)); done
else echo large-help; fi
EOF
chmod +x "$BIN"
_has_span_capability "$BIN" || fail "large capable help failed under pipefail"

# Static checks cover the production staging boundary and macOS rm-before-mv rule.
grep -q '_has_span_capability "$BIN.new"' "$ROOT/files/fzf-multicolumn.sh" \
    || fail "staged binary capability is not checked"
old_line=$(grep -n 'rm -f "$BIN"' "$ROOT/files/fzf-multicolumn.sh" | tail -1 | cut -d: -f1)
new_line=$(grep -n 'mv "$BIN.new" "$BIN"' "$ROOT/files/fzf-multicolumn.sh" | tail -1 | cut -d: -f1)
[[ "$old_line" -lt "$new_line" ]] || fail "macOS rm-before-replace ordering changed"
grep -q 'checksum mismatch' "$ROOT/files/fzf-multicolumn.sh" || fail "checksum validation was removed"

# When supplied by local E2E, probe the actual accepted upstream build through
# the exact production helper (including full help capture).
if [[ -n "${FZF_MULTICOLUMN_REAL_BIN:-}" ]]; then
    _has_span_capability "$FZF_MULTICOLUMN_REAL_BIN" || fail "real staged upstream binary failed production capability probe"
fi

echo "fzf-multicolumn capability tests passed"
