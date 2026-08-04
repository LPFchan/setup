#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export STATE_DIR="$XDG_STATE_HOME/setup"
export SETUP_SOURCE_ONLY=1
export LINUX_SETUP_SOURCE_URL="file://$TEST_TMP/src"
export SETUP_OWNER_KEYS_URL="file://$TEST_TMP/owner.keys"
mkdir -p "$HOME/.ssh" "$HOME/.local/bin" "$STATE_DIR" "$TEST_TMP/src/lib"
cp "$ROOT/lib/script-helpers.sh" "$TEST_TMP/src/lib/script-helpers.sh"

key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIORetiredCatalogKey owner'
printf '%s\n' "$key" > "$TEST_TMP/owner.keys"
printf '%s\n' "$key" > "$HOME/.ssh/id_ed25519.pub"

# A catalog with one live module and two retired ones: a script module tracked
# in script-state.tsv and a file module tracked by its target on disk.
{
    printf '# module\ttarget\tmode\tsource\taudience\tplatform\tstatus\n'
    printf 'live\t~/.local/bin/live\t0755\tbin/live\t\t\t\n'
    printf 'gone-script\t~/.local/bin/gone-script\tscript\tfiles/gone-script.sh\t\t\tretired\n'
    printf 'gone-script-disk\t~/.local/bin/gone-script-disk\tscript\tfiles/gone-script-disk.sh\t\t\tretired\n'
    printf 'gone-file\t~/.local/bin/gone-file\t0755\tbin/gone-file\t\t\tretired\n'
} > "$TEST_TMP/src/manifest.tsv"

# shellcheck disable=SC1091
source "$ROOT/bin/setup"

uname() {
    case "${1:-}" in
        -s) printf '%s\n' Linux ;;
        -m) printf '%s\n' x86_64 ;;
        *) command uname "$@" ;;
    esac
}

# Fresh machine: retired entries are invisible.
fresh=$(cmd_list)
[[ "$fresh" == *live* ]] || { echo "retired filter dropped a live module" >&2; exit 1; }
[[ "$fresh" != *gone-script* && "$fresh" != *gone-script-disk* && "$fresh" != *gone-file* ]] || {
    echo "uninstalled machine saw retired modules" >&2
    exit 1
}

# Machines that already run them keep seeing them, flagged as retired.
printf 'gone-script\t~/.local/bin/gone-script\tabc1234\tabc1234\n' > "$STATE_DIR/script-state.tsv"
: > "$HOME/.local/bin/gone-file"
: > "$HOME/.local/bin/gone-script-disk"
installed=$(cmd_list)
[[ "$installed" == *gone-script*"(retired)"* ]] || {
    echo "installed script module lost its retired entry" >&2
    exit 1
}
[[ "$installed" == *gone-file*"(retired)"* ]] || {
    echo "installed file module lost its retired entry" >&2
    exit 1
}
# A script module whose launcher is on disk but whose state registry is absent
# (pre-registry install, wiped state) must still stay visible once retired.
[[ "$installed" == *gone-script-disk*"(retired)"* ]] || {
    echo "retired script module without state entry lost its retired entry" >&2
    exit 1
}
[[ "$installed" == *live* ]] || { echo "live module vanished" >&2; exit 1; }
module_is_retired live && { echo "live module reported as retired" >&2; exit 1; }

# The cached manifest keeps its four-column shape so every consumer still
# parses source out of the last field.
while IFS=$'\t' read -r module target mode source extra; do
    [[ -z "${extra:-}" ]] || { echo "cached manifest grew a fifth column" >&2; exit 1; }
    [[ "$module" == \#* ]] && continue
    [[ "$source" == bin/* || "$source" == files/* ]] || {
        echo "cached manifest lost its source column: $source" >&2
        exit 1
    }
done < "$MANIFEST_FILE"

# Uninstalling a retired module removes it from the catalog again.
rm -f "$STATE_DIR/script-state.tsv" "$HOME/.local/bin/gone-file" "$HOME/.local/bin/gone-script-disk"
after=$(cmd_list)
[[ "$after" != *gone-script* && "$after" != *gone-script-disk* && "$after" != *gone-file* ]] || {
    echo "retired modules survived uninstall" >&2
    exit 1
}
module_is_retired gone-script && { echo "stale retired marker survived" >&2; exit 1; }

echo "catalog retired tests passed"
