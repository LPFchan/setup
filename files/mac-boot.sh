#!/usr/bin/env zsh
# setup-module: mac-boot
# setup-type: script

(( ${+functions[setup_sha256_string]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="mac-boot"
MAC_BOOT_BIN="${MAC_BOOT_BIN:-/usr/local/bin/mac-boot}"
MAC_BOOT_SUDOERS="${MAC_BOOT_SUDOERS:-/etc/sudoers.d/mac-boot}"
MAC_BOOT_SUDO="${MAC_BOOT_SUDO:-/usr/bin/sudo}"
MAC_BOOT_INSTALL="${MAC_BOOT_INSTALL:-/usr/bin/install}"
MAC_BOOT_RM="${MAC_BOOT_RM:-/bin/rm}"
MAC_BOOT_VISUDO="${MAC_BOOT_VISUDO:-/usr/sbin/visudo}"
MAC_BOOT_OWNER="${MAC_BOOT_OWNER:-root}"
MAC_BOOT_GROUP="${MAC_BOOT_GROUP:-wheel}"
MAC_BOOT_USER="${MAC_BOOT_USER:-$(id -un)}"

_render_command() {
    cat <<'EOF'
#!/bin/sh
set -eu

device_for_name() {
    volume_name="$1"
    info_file=$(mktemp)
    trap 'rm -f "$info_file"' EXIT
    /usr/sbin/diskutil info -plist "$volume_name" > "$info_file" 2>/dev/null || {
        echo "Could not find a unique volume named $volume_name." >&2
        exit 1
    }

    resolved_name=$(/usr/bin/plutil -extract VolumeName raw -o - "$info_file")
    filesystem=$(/usr/bin/plutil -extract FilesystemType raw -o - "$info_file")
    bootable=$(/usr/bin/plutil -extract Bootable raw -o - "$info_file")
    internal=$(/usr/bin/plutil -extract Internal raw -o - "$info_file")
    sealed=$(/usr/bin/plutil -extract Sealed raw -o - "$info_file")
    volume_group=$(/usr/bin/plutil -extract APFSVolumeGroupID raw -o - "$info_file")
    device_node=$(/usr/bin/plutil -extract DeviceNode raw -o - "$info_file")

    [[ "$resolved_name" = "$volume_name" \
        && "$filesystem" = apfs \
        && "$bootable" = true \
        && "$internal" = true \
        && "$sealed" = Yes \
        && -n "$volume_group" \
        && "$device_node" = /dev/disk* ]] || {
        echo "$volume_name is not a valid internal bootable macOS system volume." >&2
        exit 1
    }

    rm -f "$info_file"
    trap - EXIT
    printf '%s\n' "$device_node"
}

show_status() {
    current=$(/usr/sbin/bless --getBoot 2>/dev/null || true)
    for entry in "audio-work|Audio Work" "the-rest|The Rest"; do
        old_ifs=$IFS
        IFS='|'
        set -- $entry
        IFS=$old_ifs
        device=$(device_for_name "$2")
        marker=""
        [[ "$current" = "$device" ]] && marker=" (selected)"
        printf '%-12s %-10s %s%s\n' "$1" "${device#/dev/}" "$2" "$marker"
    done
}

case "${1:-status}" in
    status)
        show_status
        ;;
    audio-work)
        target_name="Audio Work"
        ;;
    the-rest)
        target_name="The Rest"
        ;;
    *)
        echo "Usage: mac-boot [status|audio-work|the-rest]" >&2
        exit 2
        ;;
esac

[[ "${1:-status}" = status ]] && exit 0
[[ "$(id -u)" -eq 0 ]] || {
    echo "Run partition switches with sudo." >&2
    exit 1
}

target_device=$(device_for_name "$target_name")

/usr/sbin/bless --device "$target_device" --setBoot
selected=$(/usr/sbin/bless --getBoot)
[[ "$selected" = "$target_device" ]] || {
    echo "Boot selection verification failed: expected $target_device, got $selected" >&2
    exit 1
}

echo "Boot volume set to $target_name; rebooting now."
/sbin/shutdown -r now
EOF
}

_render_sudoers() {
    printf '%s ALL=(root) NOPASSWD: %s audio-work, %s the-rest\n' \
        "$MAC_BOOT_USER" "$MAC_BOOT_BIN" "$MAC_BOOT_BIN"
}

_desired_hash() {
    { _render_command; _render_sudoers; } | setup_sha256_string
}

_file_identity() {
    local path="$1"
    if /usr/bin/stat -f '%Su:%Sg:%Lp' "$path" >/dev/null 2>&1; then
        /usr/bin/stat -f '%Su:%Sg:%Lp' "$path"
    else
        /usr/bin/stat -c '%U:%G:%a' "$path"
    fi
}

_require_admin() {
    "$MAC_BOOT_SUDO" -n /usr/bin/true 2>/dev/null && return 0
    [[ -t 0 || -t 1 || -t 2 ]] || {
        echo "mac-boot: an interactive admin password is required to install, update, or uninstall" >&2
        return 1
    }
    "$MAC_BOOT_SUDO" -v </dev/tty
}

_apply() {
    local action="$1" command_tmp sudoers_tmp hash
    printf '%s\n' "$MAC_BOOT_USER" | grep -Eq '^[A-Za-z_][A-Za-z0-9_.-]*$' || {
        echo "mac-boot: unsupported account name: $MAC_BOOT_USER" >&2
        return 1
    }
    command_tmp=$(mktemp) || return 1
    sudoers_tmp=$(mktemp) || { rm -f "$command_tmp"; return 1; }
    _render_command > "$command_tmp"
    _render_sudoers > "$sudoers_tmp"
    "$MAC_BOOT_VISUDO" -c -f "$sudoers_tmp" >/dev/null || {
        rm -f "$command_tmp" "$sudoers_tmp"
        return 1
    }
    _require_admin || { rm -f "$command_tmp" "$sudoers_tmp"; return 1; }
    "$MAC_BOOT_SUDO" "$MAC_BOOT_INSTALL" -o "$MAC_BOOT_OWNER" -g "$MAC_BOOT_GROUP" -m 0755 \
        "$command_tmp" "$MAC_BOOT_BIN" || { rm -f "$command_tmp" "$sudoers_tmp"; return 1; }
    "$MAC_BOOT_SUDO" "$MAC_BOOT_INSTALL" -o "$MAC_BOOT_OWNER" -g "$MAC_BOOT_GROUP" -m 0440 \
        "$sudoers_tmp" "$MAC_BOOT_SUDOERS" || { rm -f "$command_tmp" "$sudoers_tmp"; return 1; }
    rm -f "$command_tmp" "$sudoers_tmp"
    hash=$(_desired_hash)
    record_script_state "$MODULE" "privileged-files" "$hash" "$hash"
    echo "mac-boot: $action -> $MAC_BOOT_BIN"
}

install() {
    _apply installed
}

update() {
    _apply updated
}

status() {
    if [[ ! -f "$MAC_BOOT_BIN" || ! -f "$MAC_BOOT_SUDOERS" ]]; then
        printf '%-25s %-12s target=%s\n' "$MODULE" "uninstalled" "$MAC_BOOT_BIN"
        return 2
    fi

    local desired desired_command current state
    desired=$(_desired_hash)
    desired_command=$(_render_command | setup_sha256_string)
    current=$(setup_sha256_string < "$MAC_BOOT_BIN")
    state="current"
    [[ "$current" == "$desired_command" ]] || state="outdated"
    [[ "$(_file_identity "$MAC_BOOT_BIN")" == "$MAC_BOOT_OWNER:$MAC_BOOT_GROUP:755" ]] || state="outdated"
    [[ "$(_file_identity "$MAC_BOOT_SUDOERS")" == "$MAC_BOOT_OWNER:$MAC_BOOT_GROUP:440" ]] || state="outdated"
    "$MAC_BOOT_SUDO" -n -l "$MAC_BOOT_BIN" audio-work >/dev/null 2>&1 || state="outdated"
    "$MAC_BOOT_SUDO" -n -l "$MAC_BOOT_BIN" the-rest >/dev/null 2>&1 || state="outdated"

    if [[ "$state" == "current" ]]; then
        record_script_state "$MODULE" "privileged-files" "$desired" "$desired"
    fi
    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "$MODULE" "$state" "${current:0:7}" "${desired_command:0:7}" "$MAC_BOOT_BIN"
    [[ "$state" == "current" ]]
}

uninstall() {
    _require_admin || return 1
    "$MAC_BOOT_SUDO" "$MAC_BOOT_RM" -f "$MAC_BOOT_BIN" "$MAC_BOOT_SUDOERS" || return 1
    remove_script_state "$MODULE"
    echo "mac-boot: removed -> $MAC_BOOT_BIN"
}
