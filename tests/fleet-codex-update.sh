#!/usr/bin/env bash
# fleet's Codex update: `codex update`, and Codex's own installer when that
# cannot tell how Codex was installed.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

command=$(python3 -c 'import json, sys
specs = {h["name"]: h for h in json.load(open(sys.argv[1]))["harnesses"]}
print(specs["codex"]["update"])' "$ROOT/files/fleet-manifest.json")

mkdir -p "$TMP/bin"
# curl hands back an "installer" that records how it ran.
printf '#!/bin/sh\necho "echo installer CODEX_NON_INTERACTIVE=\\$CODEX_NON_INTERACTIVE >> %s/calls"\n' "$TMP" > "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
codex_stub() {
    printf '#!/bin/sh\necho "codex $*" >> %s/calls\nexit %s\n' "$TMP" "$1" > "$TMP/bin/codex"
    chmod +x "$TMP/bin/codex"
    : > "$TMP/calls"
}
# fleet runs manifest commands the same way (files/fleet, _shell).
run() { PATH="$TMP/bin:/usr/bin:/bin" bash -o pipefail -c "$command"; }

codex_stub 0
run || fail "a working codex update failed"
[[ "$(cat "$TMP/calls")" == "codex update" ]] || fail "the installer ran after a working codex update: $(cat "$TMP/calls")"

codex_stub 1
run || fail "the installer fallback failed"
[[ "$(cat "$TMP/calls")" == $'codex update\ninstaller CODEX_NON_INTERACTIVE=1' ]] \
    || fail "codex update failing did not run the installer non-interactively: $(cat "$TMP/calls")"

echo "fleet codex update tests passed"
