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
export MAC_BOOT_USER="test-user"
mkdir -p "$HOME" "${MAC_BOOT_BIN:h}" "${MAC_BOOT_SUDOERS:h}"

cat > "$MAC_BOOT_SUDO" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -n ]; then
    shift
    if [ "${FAKE_SUDO_REJECT_ADMIN:-0}" = 1 ] && [ "${1:-}" = /usr/bin/true ]; then
        exit 1
    fi
fi
if [ "${1:-}" = -l ]; then exit 0; fi
if [ "${1:-}" = -v ]; then exit 0; fi
exec "$@"
EOF
chmod +x "$MAC_BOOT_SUDO"
printf '#!/bin/sh\nexit 0\n' > "$MAC_BOOT_VISUDO"
chmod +x "$MAC_BOOT_VISUDO"

# shellcheck disable=SC1091
source "$ROOT/lib/script-helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/files/mac-boot.sh"

status >/dev/null 2>&1 && { echo "missing module reported current" >&2; exit 1; }
install >/dev/null
status >/dev/null
grep -Fqx "test-user ALL=(root) NOPASSWD: $MAC_BOOT_BIN *" "$MAC_BOOT_SUDOERS" \
    || { echo "narrow passwordless sudo rule was not installed" >&2; exit 1; }
grep -Fq 'diskutil info -plist "$volume_ref"' "$MAC_BOOT_BIN" \
    || { echo "helper does not discover volumes by name" >&2; exit 1; }
grep -Fq 'APFSVolumeGroupID' "$MAC_BOOT_BIN" \
    || { echo "helper does not validate APFS volume groups" >&2; exit 1; }
grep -Fq 'APFSSnapshot' "$MAC_BOOT_BIN" \
    || { echo "helper does not exclude APFS snapshots" >&2; exit 1; }
grep -Fq 'tell application "loginwindow" to «event aevtrrst»' "$MAC_BOOT_BIN" \
    || { echo "helper does not request the standard macOS restart dialog" >&2; exit 1; }
if grep -Fq '/sbin/shutdown -r now' "$MAC_BOOT_BIN"; then
    echo "helper still forces an immediate restart" >&2
    exit 1
fi
grep -Fq 'target_name="$1"' "$MAC_BOOT_BIN" \
    || { echo "helper does not accept literal volume names" >&2; exit 1; }
grep -Fq '/usr/bin/sudo -n "$self" --set-boot "$target_name"' "$MAC_BOOT_BIN" \
    || { echo "helper can still display a misleading sudo password prompt" >&2; exit 1; }
grep -Fq 'diskutil apfs listVolumeGroups -plist' "$MAC_BOOT_BIN" \
    || { echo "status does not discover APFS system volumes" >&2; exit 1; }
grep -Fq 'volume_role" = System' "$MAC_BOOT_BIN" \
    || { echo "status does not exclude APFS data volumes" >&2; exit 1; }
grep -Fq "printf 'available" "$MAC_BOOT_BIN" \
    || { echo "status does not label available boot volumes" >&2; exit 1; }
mac_boot_help=$("$MAC_BOOT_BIN" --help)
[[ "$mac_boot_help" == *'mac-boot [status|--help|volume-name]'* ]] \
    || { echo "helper does not document its arguments" >&2; exit 1; }
[[ "$mac_boot_help" == *'open the restart dialog'* ]] \
    || { echo "helper help does not describe the graceful restart" >&2; exit 1; }
if grep -Fq 'Audio Work' "$MAC_BOOT_BIN" || grep -Fq 'The Rest' "$MAC_BOOT_BIN"; then
    echo "helper hardcodes this machine's volume names" >&2
    exit 1
fi

printf '\n# drift\n' >> "$MAC_BOOT_BIN"
status >/dev/null 2>&1 && { echo "modified helper reported current" >&2; exit 1; }
export SETUP_BATCH=1 FAKE_SUDO_REJECT_ADMIN=1
if update >/dev/null 2>&1; then
    echo "batch update did not defer without cached admin authentication" >&2
    exit 1
else
    rc=$?
fi
[[ "$rc" -eq 75 ]] || { echo "batch update returned $rc instead of deferred status" >&2; exit 1; }
status >/dev/null 2>&1 && { echo "deferred update unexpectedly changed the helper" >&2; exit 1; }
export SETUP_BATCH=0 FAKE_SUDO_REJECT_ADMIN=0
update >/dev/null
status >/dev/null
uninstall >/dev/null
[[ ! -e "$MAC_BOOT_BIN" && ! -e "$MAC_BOOT_SUDOERS" ]] \
    || { echo "uninstall left privileged files behind" >&2; exit 1; }

echo "mac-boot tests passed"
