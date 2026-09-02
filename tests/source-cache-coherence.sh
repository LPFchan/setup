#!/usr/bin/env zsh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export SETUP_SOURCE_ONLY=1
unset LINUX_SETUP_SOURCE_URL
mkdir -p "$HOME" "$XDG_STATE_HOME"

PINNED_REVISION=1111111111111111111111111111111111111111

curl() {
    local output="" url="" arg saw_header=0
    for arg in "$@"; do
        [[ "$arg" == "Cache-Control: no-cache" ]] && saw_header=1
        [[ "$arg" == *://* ]] && url="$arg"
    done
    while (($#)); do
        if [[ "$1" == -o ]]; then
            output="$2"
            break
        fi
        shift
    done
    if [[ "$url" == https://github.com/LPFchan.keys ]]; then
        : > "$output"
        return 0
    fi
    [[ "$saw_header" -eq 1 ]] || {
        echo "source fetch omitted cache revalidation: $url" >&2
        return 1
    }
    printf '%s\n' "$url" >> "$TEST_TMP/fetches"
    case "$url" in
        https://api.github.com/repos/LPFchan/setup/git/ref/heads/main)
            printf '{"object":{"sha":"%s"}}\n' "$PINNED_REVISION" ;;
        */lib/script-helpers.sh) cp "$ROOT/lib/script-helpers.sh" "$output" ;;
        */manifest.tsv) printf '# module\ttarget\tmode\tsource\n' > "$output" ;;
        */checksums.tsv) printf '# source\tsha256\n' > "$output" ;;
        */bin/setup) printf '# setup-module: setup\n' > "$output" ;;
        *) return 1 ;;
    esac
}

# shellcheck disable=SC1091
source "$ROOT/bin/setup"

fetch_manifest
_CSUM_CACHE=""
fetch_checksums
payload="$TEST_TMP/payload"
fetch_payload bin/setup "$payload"

[[ $(wc -l < "$TEST_TMP/fetches") -eq 5 ]] || {
    echo "not every source surface was fetched through cache revalidation" >&2
    cat "$TEST_TMP/fetches" >&2
    exit 1
}
PINNED_SOURCE="https://raw.githubusercontent.com/LPFchan/setup/$PINNED_REVISION"
for expected in lib/script-helpers.sh manifest.tsv checksums.tsv bin/setup; do
    grep -Fxq "$PINNED_SOURCE/$expected" "$TEST_TMP/fetches" || {
        echo "missing pinned source fetch: $expected" >&2
        exit 1
    }
done
if grep -F 'https://raw.githubusercontent.com/LPFchan/setup/' "$TEST_TMP/fetches" \
    | grep -Fv "$PINNED_SOURCE/" \
    | grep -q .; then
    echo "source fetch escaped the pinned revision" >&2
    exit 1
fi

echo "source cache coherence tests passed"
