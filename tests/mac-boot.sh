#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export STATE_DIR="$TEST_TMP/state"
export MAC_BOOT_BIN="$TEST_TMP/usr/local/bin/mac-boot"
export MAC_BOOT_SUDOERS="$TEST_TMP/etc/sudoers.d/mac-boot"
export MAC_BOOT_OWNER="$(id -un)"
export MAC_BOOT_GROUP="$(id -gn)"
export MAC_BOOT_SUDO="$TEST_TMP/fake-sudo"
export MAC_BOOT_VISUDO="$TEST_TMP/fake-visudo"
mkdir -p "$HOME" "${MAC_BOOT_BIN:h}" "${MAC_BOOT_SUDOERS:h}"

cat > "$MAC_BOOT_SUDO" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -n ]; then shift; fi
if [ "${1:-}" = -l ]; then exit 0; fi
if [ "${1:-}" = -v ]; then exit 0; fi
exec "$@"
EOF
cat > "$MAC_BOOT_VISUDO" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MAC_BOOT_SUDO" "$MAC_BOOT_VISUDO"

# shellcheck disable=SC1091
source "$ROOT/lib/script-helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/files/mac-boot.sh"

status >/dev/null 2>&1 && { echo "missing module reported current" >&2; exit 1; }
install >/dev/null
status >/dev/null
grep -Fqx "$(id -un) ALL=(root) NOPASSWD: $MAC_BOOT_BIN *" \
    "$MAC_BOOT_SUDOERS" || { echo "sudo rule is not exact" >&2; exit 1; }
grep -Fq 'diskutil info -plist "$volume_name"' "$MAC_BOOT_BIN" \
    || { echo "helper does not discover volumes by name" >&2; exit 1; }
grep -Fq 'APFSVolumeGroupID' "$MAC_BOOT_BIN" \
    || { echo "helper does not validate APFS volume groups" >&2; exit 1; }
grep -Fq '/sbin/shutdown -r now' "$MAC_BOOT_BIN" \
    || { echo "helper does not reboot after selection" >&2; exit 1; }
grep -Fq 'target_name="$1"' "$MAC_BOOT_BIN" \
    || { echo "helper does not accept literal volume names" >&2; exit 1; }
if grep -Fq 'Audio Work' "$MAC_BOOT_BIN" || grep -Fq 'The Rest' "$MAC_BOOT_BIN"; then
    echo "helper hardcodes this machine's volume names" >&2
    exit 1
fi

printf '\n# drift\n' >> "$MAC_BOOT_BIN"
status >/dev/null 2>&1 && { echo "modified helper reported current" >&2; exit 1; }
update >/dev/null
status >/dev/null
uninstall >/dev/null
[[ ! -e "$MAC_BOOT_BIN" && ! -e "$MAC_BOOT_SUDOERS" ]] \
    || { echo "uninstall left privileged files behind" >&2; exit 1; }

echo "mac-boot tests passed"
