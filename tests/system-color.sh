#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export LINUX_SETUP_SOURCE_URL="file://$ROOT"
export SETUP_SOURCE_ONLY=1
export TEST_HOSTNAME="test-host"
FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$FAKE_BIN"

cat > "$FAKE_BIN/hostname" <<'EOF'
#!/bin/sh
printf '%s\n' "$TEST_HOSTNAME"
EOF
chmod +x "$FAKE_BIN/hostname"
PATH="$FAKE_BIN:$PATH"
export PATH TEST_HOSTNAME

# shellcheck disable=SC1091
source "$ROOT/bin/setup"
# shellcheck disable=SC1091
source "$ROOT/files/zsh-basics.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

install >/dev/null

[[ "$SYSTEM_COLOR_HUE" == "270" ]] \
    || fail "unexpected deterministic hue: $SYSTEM_COLOR_HUE"
[[ "$SYSTEM_COLOR_HEX" == "#7F00FF" ]] \
    || fail "unexpected HSV color: $SYSTEM_COLOR_HEX"
[[ "$SYSTEM_COLOR_TEXT_HEX" == "#FFFFFF" ]] \
    || fail "unexpected contrast color: $SYSTEM_COLOR_TEXT_HEX"
[[ -n "${SYSTEM_COLOR_HUE+x}" && -n "${SYSTEM_COLOR_HEX+x}" ]] \
    || fail "system color values were not exported"
has_managed_block "$HOME/.zshenv" system-color \
    || fail "zsh-basics did not install the .zshenv system-color block"
grep -Fq "alias ll='ls -alFh'" "$HOME/.zshrc" \
    || fail "zsh-basics did not install the ll alias"

# Full saturation/value means every generated RGB triplet has at least one
# channel at 00 and at least one at FF.
rgb=${SYSTEM_COLOR_HEX#\#}
r=$((16#${rgb:0:2})); g=$((16#${rgb:2:2})); b=$((16#${rgb:4:2}))
min=$r; max=$r
((g < min)) && min=$g; ((b < min)) && min=$b
((g > max)) && max=$g; ((b > max)) && max=$b
[[ "$min" -eq 0 && "$max" -eq 255 ]] \
    || fail "generated color is not S=100%, B/V=100%: $SYSTEM_COLOR_HEX"

if status >/dev/null; then
    status_rc=0
else
    status_rc=$?
fi
[[ "$status_rc" -eq 0 ]] || fail "fresh combined zsh-basics state is not current"

# A fresh zsh process must derive the same shared values from the installed
# global block, without setup being present in that process.
zsh_values=$(zsh -dfc 'source "$1"; print -r -- "$SYSTEM_COLOR_HUE $SYSTEM_COLOR_HEX $SYSTEM_COLOR_TEXT_HEX"' _ "$HOME/.zshenv")
[[ "$zsh_values" == "270 #7F00FF #FFFFFF" ]] \
    || fail "fresh zsh derived different values: $zsh_values"

# Hostname is the only input: another hostname deterministically changes hue.
TEST_HOSTNAME="another-host"
export TEST_HOSTNAME
source "$HOME/.zshenv"
[[ "$SYSTEM_COLOR_HUE" != "270" && "$SYSTEM_COLOR_HEX" != "#7F00FF" ]] \
    || fail "changing hostname did not change the system color"

# Missing either owned surface is drift, not an uninstalled module.
manage_block "$HOME/.zshenv" system-color "" remove >/dev/null
if status >/dev/null; then
    drift_rc=0
else
    drift_rc=$?
fi
[[ "$drift_rc" -eq 1 ]] || fail "missing system-color block did not report zsh-basics outdated"

echo "system color tests passed"
