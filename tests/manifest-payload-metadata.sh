#!/usr/bin/env zsh
# Every installable payload must declare its own module name. fetch_payload
# rejects anything without a `# setup-module:` header, so a manifest row whose
# source lacks one can be listed and selected but never actually installed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

failures=0
while IFS=$'\t' read -r module target mode source audience platform state; do
    [[ -z "${module:-}" || "$module" == \#* ]] && continue
    [[ "${state:-}" == retired ]] && continue
    [[ -n "${source:-}" ]] || continue
    [[ -f "$source" ]] || { echo "  $module: source $source is missing" >&2; failures=$((failures + 1)); continue; }
    declared=$(sed -n 's/^# setup-module: //p' "$source" | head -1)
    if [[ -z "$declared" ]]; then
        echo "  $module: $source has no '# setup-module:' header; setup install $module would fail" >&2
        failures=$((failures + 1))
    elif [[ "$declared" != "$module" ]]; then
        echo "  $module: $source declares '$declared'" >&2
        failures=$((failures + 1))
    fi
done < manifest.tsv

((failures == 0)) || fail "$failures manifest payload(s) cannot be installed"
echo "manifest payload metadata ok"
