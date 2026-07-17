#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export LINUX_SETUP_SOURCE_URL="file://$ROOT"
export SETUP_SOURCE_ONLY=1
mkdir -p "$HOME" "$XDG_STATE_HOME"

# shellcheck disable=SC1091
source "$ROOT/bin/setup"

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
    [[ "$saw_header" -eq 1 ]] || {
        echo "source fetch omitted cache revalidation: $url" >&2
        return 1
    }
    printf '%s\n' "$url" >> "$TEST_TMP/fetches"
    case "$url" in
        */manifest.tsv) printf '# module\ttarget\tmode\tsource\n' > "$output" ;;
        */checksums.tsv) printf '# source\tsha256\n' > "$output" ;;
        */bin/setup) printf '# setup-module: setup\n' > "$output" ;;
        *) return 1 ;;
    esac
}

fetch_manifest
_CSUM_CACHE=""
fetch_checksums
payload="$TEST_TMP/payload"
fetch_payload bin/setup "$payload"

[[ $(wc -l < "$TEST_TMP/fetches") -eq 3 ]] || {
    echo "not every source surface was fetched through cache revalidation" >&2
    exit 1
}

echo "source cache coherence tests passed"
