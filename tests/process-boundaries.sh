#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Executable boundary: command failure wins; post-auth still runs and its own
# failure cannot mask or replace the original command status.
make_source() {
    local dir="$1" body="$2"
    mkdir -p "$dir/lib"
    cp "$ROOT/bin/setup" "$dir/bin-setup"
    cp "$ROOT/lib/script-helpers.sh" "$dir/lib/script-helpers.sh"
    printf '# module\ttarget\tmode\tsource\nfail\t~/fail\tscript\tfail.sh\n' > "$dir/manifest.tsv"
    printf '%s\n' "$body" > "$dir/fail.sh"
    printf '# source\tsha256\n' > "$dir/checksums.tsv"
}
source_dir="$TMP/source"
make_source "$source_dir" '# setup-module: fail
install() { return 7; }
status() { printf "%-25s %-12s\n" fail uninstalled; return 2; }
update() { return 8; }'
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
mkdir -p "$HOME/.local/bin" "$XDG_STATE_HOME/setup"
cp "$ROOT/files/refresh-models" "$HOME/.local/bin/refresh-models"
chmod +x "$HOME/.local/bin/refresh-models"
printf x > "$XDG_STATE_HOME/setup/refresh-models.needs-auth"
if output=$(LINUX_SETUP_SOURCE_URL="file://$source_dir" zsh "$ROOT/bin/setup" install fail 2>&1); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || { echo "install status was masked by post-auth" >&2; exit 1; }
[[ "$output" == *'needs API keys'* ]] || { echo "post-auth did not run after failed install" >&2; exit 1; }

# Fresh offline no-TTY fallback must fail at manifest fetch and never claim
# current/up-to-date or create a stale manifest.
offline_home="$TMP/offline-home"
if output=$(HOME="$offline_home" XDG_STATE_HOME="$TMP/offline-state" LINUX_SETUP_SOURCE_URL="file://$TMP/missing" zsh "$ROOT/bin/setup" --batch 2>&1); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || { echo "offline batch update returned success" >&2; exit 1; }
[[ "$output" == *'Failed to fetch manifest'* ]] || { echo "offline batch output was not actionable: $output" >&2; exit 1; }
[[ "$output" != *'All modules up to date'* ]] || { echo "offline batch falsely claimed up-to-date" >&2; exit 1; }
[[ ! -e "$TMP/offline-state/setup/manifest.tsv" ]] || { echo "failed fetch left stale manifest" >&2; exit 1; }

echo "process boundary tests passed"
