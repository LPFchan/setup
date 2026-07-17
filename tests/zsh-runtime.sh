#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

runtime_files=(install.sh bin/setup lib/script-helpers.sh)
while IFS=$'\t' read -r _module _target mode source; do
    [[ "$mode" == script ]] && runtime_files+=("$source")
done < "$ROOT/manifest.tsv"

for runtime_file in "${runtime_files[@]}"; do
    [[ "$(head -1 "$ROOT/$runtime_file")" == '#!/usr/bin/env zsh' ]] \
        || fail "$runtime_file does not select zsh"
    zsh -n "$ROOT/$runtime_file" || fail "$runtime_file is not valid zsh"
done

if SETUP_SOURCE_ONLY=1 bash "$ROOT/bin/setup" >/dev/null 2>&1; then
    fail "bin/setup accepted Bash"
fi
if SETUP_INSTALL_SOURCE_ONLY=1 bash "$ROOT/install.sh" >/dev/null 2>&1; then
    fail "install.sh accepted Bash"
fi

echo "zsh runtime tests passed"
