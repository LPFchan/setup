#!/bin/sh
# Enroll a macOS or Linux machine in the fleet:
#   curl -fsSL https://auth.lost.plus/fleet.sh | sh
# Fetches fleet from one commit and runs `fleet self-install`, which installs
# auth and fleet into ~/.local/bin, puts it on PATH, signs in, syncs and
# schedules the nightly pass. Run it again to repair or update. --pull syncs
# without pushing local edits; setup's fleet module hands a machine over with it.
#
# POSIX sh: some machines (a Synology NAS) have no system zsh or bash. All of
# it sits in main, so a download cut short runs nothing.

main() {
    set -eu
    command -v python3 >/dev/null 2>&1 || die "fleet needs python3 3.9 or newer; install it and run this again"
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' </dev/null \
        || die "fleet needs python3 3.9 or newer, found $(python3 -V 2>&1); install a newer one and run this again"

    # Resolve main once, as bin/setup does, so every file comes from one commit.
    # SOURCE_URL may also be a local checkout.
    source="${SOURCE_URL:-}"
    if [ -z "$source" ]; then
        source=https://raw.githubusercontent.com/LPFchan/setup/main
        sha=$(curl -fsSL --max-time 30 https://api.github.com/repos/LPFchan/setup/git/ref/heads/main 2>/dev/null \
            | sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n 1) || sha=
        [ -n "$sha" ] && source="https://raw.githubusercontent.com/LPFchan/setup/$sha"
    fi

    # A private directory: Python imports from the script's own directory first.
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    trap 'exit 1' HUP INT TERM
    if [ -d "$source" ]; then
        cp "$source/files/fleet" "$dir/fleet"
    else
        curl -fsSL --max-time 60 "$source/files/fleet" -o "$dir/fleet" || die "could not fetch fleet from $source"
    fi
    SOURCE_URL="$source" python3 "$dir/fleet" self-install "$@" </dev/null
}

die() { echo "fleet: $*" >&2; exit 1; }

main "$@"
