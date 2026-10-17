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
export LOG="$TEST_TMP/log"
mkdir -p "$HOME/.ssh" "$HOME/.local/bin" "$STATE_DIR" "$TEST_TMP/src/lib" "$TEST_TMP/src/files"
cp "$ROOT/lib/script-helpers.sh" "$TEST_TMP/src/lib/script-helpers.sh"
printf 'ssh-ed25519 AAAAOwnerKey owner\n' > "$TEST_TMP/owner.keys"
printf 'ssh-ed25519 AAAAOtherKey me\n' > "$HOME/.ssh/id_ed25519.pub"
fail() { print -u2 -- "FAIL: $*"; exit 1; }

# A stand-in auth whose context names $TEST_TMP/subject, fails without it,
# and reports a revoked session (rc 4) while $TEST_TMP/revoked exists.
cat > "$HOME/.local/bin/auth" <<SH
#!/bin/sh
[ -e "$TEST_TMP/revoked" ] && exit 4
[ "\$1" = context ] && [ -s "$TEST_TMP/subject" ] || exit 1
printf '{"origin":"https://auth.lost.plus","subject":"%s"}\n' "\$(cat "$TEST_TMP/subject")"
SH
chmod +x "$HOME/.local/bin/auth"

# Script modules that log every call. `next` fails its install while
# $TEST_TMP/broken exists; `old` must never run at all.
for name in old next dep owner-only; do
    cat > "$TEST_TMP/src/files/$name.sh" <<SH
# setup-module: $name
install() { echo "$name install SWAP=\${SETUP_SWAP_FROM:-}" >> "\$LOG"; [[ "$name" != next || ! -e "$TEST_TMP/broken" ]] || return 1; record_script_state $name x 1 1; }
update() { echo "$name update" >> "\$LOG"; [[ "$name" != next || ! -e "$TEST_TMP/broken-update" ]] || return 1; record_script_state $name x 1 1; }
status() { echo "$name status" >> "\$LOG"; printf '%-25s %-12s\n' $name "\${STATUS:-current}"; [[ "\${STATUS:-current}" == current ]]; }
uninstall() { echo "$name uninstall" >> "\$LOG"; remove_script_state $name; }
SH
done
{
    printf '# module\ttarget\tmode\tsource\taudience\tplatform\tstatus\trequires\tsuccessor\n'
    printf 'dep\t-\tscript\tfiles/dep.sh\t\t\t\t\t\n'
    printf 'next\t-\tscript\tfiles/next.sh\t\t\t\tdep\t\n'
    printf 'old\t~/.ssh/config\tscript\tfiles/old.sh\tfleet\t\tretired\t\tnext\n'
    printf 'owner-only\t-\tscript\tfiles/owner-only.sh\tfleet\t\t\t\t\n'
} > "$TEST_TMP/src/manifest.tsv"

# shellcheck disable=SC1091
source "$ROOT/bin/setup"
uname() { case "${1:-}" in -s) print Darwin ;; *) command uname "$@" ;; esac; }
state_has() { grep -q "^$1"$'\t' "$STATE_DIR/script-state.tsv" 2>/dev/null; }

# A retired module with a successor leaves the catalog; only the mapping stays.
fetch_manifest >/dev/null 2>&1
grep -q '^old' "$MANIFEST_FILE" && fail "retired module with a successor stayed in the catalog"
[[ "$(module_successor old)" == next ]] || fail "successor not recorded"

# The swap: dependency first, then the successor (told it is a swap), then the
# old state entry goes. The old module's script never runs.
printf 'old\tx\t1\t1\n' > "$STATE_DIR/script-state.tsv"
touch "$TEST_TMP/broken"; : > "$LOG"
swap_retired_modules >/dev/null 2>&1 && fail "swap reported success after a failed install"
state_has old || fail "a failed install dropped the old state entry"
# A failed install that left the successor's state entry behind is retried,
# not taken as done.
printf 'next\tx\t1\t1\n' >> "$STATE_DIR/script-state.tsv"
swap_retired_modules >/dev/null 2>&1 && fail "swap took a half-installed successor as done"
state_has old || fail "a half-installed successor dropped the old state entry"
[[ "$(head -1 "$LOG")" == "dep install"* ]] || fail "dependency not installed first: $(cat "$LOG")"
rm "$TEST_TMP/broken"; : > "$LOG"
swap_retired_modules >/dev/null 2>&1 || fail "swap"
state_has old && fail "old state entry kept after the swap"
state_has next || fail "successor not installed"
grep -q "next install SWAP=old" "$LOG" || fail "successor not told it replaces old"
grep -q "^old " "$LOG" && fail "the old module's script ran"
# Once the old state entry is gone the successor runs again, so whatever it
# held back while its predecessor was recorded happens in the same run.
[[ "$(tail -1 "$LOG")" == "next update" ]] || fail "successor not rerun after the swap: $(cat "$LOG")"
: > "$LOG"
swap_retired_modules >/dev/null 2>&1 || fail "second swap"
[[ ! -s "$LOG" ]] || fail "swap ran again with nothing to do: $(cat "$LOG")"
# A rerun that fails after the swap is owed until it succeeds, though the old
# state entry that started the swap is gone.
printf 'old\tx\t1\t1\n' >> "$STATE_DIR/script-state.tsv"
touch "$TEST_TMP/broken-update"
swap_retired_modules >/dev/null 2>&1 && fail "swap reported success after a failed rerun"
state_has old && fail "old state entry kept after a swap whose rerun failed"
rm "$TEST_TMP/broken-update"; : > "$LOG"
swap_retired_modules >/dev/null 2>&1 || fail "retry of a failed rerun"
[[ "$(cat "$LOG")" == "next update" ]] || fail "failed rerun not retried: $(cat "$LOG")"
: > "$LOG"
swap_retired_modules >/dev/null 2>&1 || fail "swap after the retried rerun"
[[ ! -s "$LOG" ]] || fail "a finished rerun ran again: $(cat "$LOG")"
# A swap that cannot write its retry marker keeps the old state entry.
printf 'old\tx\t1\t1\n' >> "$STATE_DIR/script-state.tsv"
: > "$SWAP_PENDING_FILE"; chmod 400 "$SWAP_PENDING_FILE"
swap_retired_modules >/dev/null 2>&1 && fail "swap passed with an unwritable retry marker"
chmod 600 "$SWAP_PENDING_FILE"; rm -f "$SWAP_PENDING_FILE"
state_has old || fail "an unwritable retry marker dropped the old state entry"
swap_retired_modules >/dev/null 2>&1 || fail "swap once the marker is writable"
# So does one whose old state entry cannot be dropped, and its retry marker
# stays for the next run.
printf 'old\tx\t1\t1\n' >> "$STATE_DIR/script-state.tsv"
functions -c remove_script_state real_remove_script_state
remove_script_state() { [[ "$1" == old ]] && return 1; real_remove_script_state "$@"; }
rc=0; swap_retired_modules >/dev/null 2>&1 || rc=$?
functions -c real_remove_script_state remove_script_state
(( rc != 0 )) || fail "swap passed with an undroppable old state entry"
state_has old || fail "an undroppable old state entry vanished"
grep -qx next "$SWAP_PENDING_FILE" || fail "an undroppable old state entry cleared the retry marker"
swap_retired_modules >/dev/null 2>&1 || fail "swap once the old state entry can go"
state_has old && fail "old state entry kept once it can go"
[[ ! -e "$SWAP_PENDING_FILE" ]] || fail "retry marker left after the takeover finished"
# A takeover whose retry marker cannot be rewritten is not reported done.
printf 'next\nghost\n' > "$SWAP_PENDING_FILE"; mkdir "$SWAP_PENDING_FILE.tmp"
swap_retired_modules >/dev/null 2>&1 && fail "swap passed with a retry marker it could not clear"
grep -qx next "$SWAP_PENDING_FILE" || fail "an uncleared retry marker lost the takeover"
rmdir "$SWAP_PENDING_FILE.tmp"
chmod 000 "$SWAP_PENDING_FILE"
swap_retired_modules >/dev/null 2>&1 && fail "swap passed with a retry marker it could not read"
chmod 600 "$SWAP_PENDING_FILE"
grep -qx next "$SWAP_PENDING_FILE" || fail "an unreadable retry marker lost the takeover"
swap_retired_modules >/dev/null 2>&1 || fail "swap once the retry marker can be cleared"
[[ ! -e "$SWAP_PENDING_FILE" ]] || fail "retry marker left once it can be cleared"
# A state file that cannot be read keeps a takeover owed, not settled as
# though its successor were gone.
printf 'next\n' > "$SWAP_PENDING_FILE"; chmod 000 "$STATE_DIR/script-state.tsv"; : > "$LOG"
swap_retired_modules >/dev/null 2>&1 && fail "swap passed with a state file it could not read"
chmod 600 "$STATE_DIR/script-state.tsv"
grep -qx next "$SWAP_PENDING_FILE" || fail "an unreadable state file cleared the retry marker"
swap_retired_modules >/dev/null 2>&1 || fail "swap once the state file can be read"
grep -q "next update" "$LOG" || fail "the owed takeover did not run once the state file could be read: $(cat "$LOG")"
[[ ! -e "$SWAP_PENDING_FILE" ]] || fail "retry marker left once the state file can be read"

# An outdated dependency is updated before the successor goes in.
printf 'old\tx\t1\t1\n' >> "$STATE_DIR/script-state.tsv"
STATUS=outdated swap_retired_modules >/dev/null 2>&1 || true
grep -q "dep update" "$LOG" || fail "outdated dependency not updated"

# `setup install old` installs its successor.
remove_script_state next; remove_script_state old; : > "$LOG"
cmd_install old >/dev/null 2>&1 || fail "install of a retired name"
grep -q "next install" "$LOG" || fail "install of a retired name did not install its successor"
grep -q "^old " "$LOG" && fail "install of a retired name ran the old module"

# Operator-only modules: subject 1 passes without a key match.
printf 1 > "$TEST_TMP/subject"
fetch_manifest >/dev/null 2>&1
module_in_catalog owner-only || fail "subject 1 did not see an operator-only module"
# Another account without a key match does not.
printf 7 > "$TEST_TMP/subject"
fetch_manifest >/dev/null 2>&1
module_in_catalog owner-only && fail "subject 7 saw an operator-only module"
# The owner's key alone still passes.
printf 'ssh-ed25519 AAAAOwnerKey me\n' > "$HOME/.ssh/id_ed25519.pub"
fetch_manifest >/dev/null 2>&1
module_in_catalog owner-only || fail "key match alone did not pass"
printf 'ssh-ed25519 AAAAOtherKey me\n' > "$HOME/.ssh/id_ed25519.pub"
# With no session, an installed one stays (with a warning); a missing one stays hidden.
rm "$TEST_TMP/subject"
fetch_manifest >/dev/null 2>&1
module_in_catalog owner-only && fail "no session offered an operator-only module"
printf 'owner-only\tx\t1\t1\n' >> "$STATE_DIR/script-state.tsv"
fetch_manifest 2>"$TEST_TMP/err" >/dev/null
module_in_catalog owner-only || fail "no session hid an installed operator-only module"
grep -q 'keeping its operator-only modules: owner-only' "$TEST_TMP/err" || fail "no warning for a kept module"
# A revoked session is an answer, not a missing one: installed modules go too.
touch "$TEST_TMP/revoked"
fetch_manifest >/dev/null 2>&1
module_in_catalog owner-only && fail "a revoked session kept an operator-only module"
rm "$TEST_TMP/revoked"

# Every successor in the real catalog is offered to every account: a retired
# module can be installed anywhere, and its replacement must be too.
hidden=$(awk -F '\t' '$1 !~ /^#/ { audience[$1] = $5; if ($7 == "retired" && $9 != "") want[$9] = 1 }
    END { for (m in want) if (audience[m] != "") print m }' "$ROOT/manifest.tsv")
[[ -z "$hidden" ]] || fail "a successor is operator-only: $hidden"

# A retired module not swapped yet still uninstalls through its own script.
printf 'old\tx\t1\t1\n' > "$STATE_DIR/script-state.tsv"; : > "$LOG"
BATCH=1 cmd_uninstall old >/dev/null 2>&1 || fail "uninstall of an unswapped retired module"
grep -qx "old uninstall" "$LOG" || fail "the retired module's cleanup did not run: $(cat "$LOG")"
state_has old && fail "uninstall kept the retired module's state entry"

# The cached manifest stays four columns for older binaries.
[[ "$(awk -F '\t' 'NF { print NF }' "$MANIFEST_FILE" | sort -u)" == 4 ]] || fail "cached manifest is not four columns"
echo "retired successor tests passed"
