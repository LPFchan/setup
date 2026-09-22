#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" SETUP_SOURCE_ONLY=1
mkdir -p "$HOME" "$XDG_STATE_HOME/setup"
# shellcheck disable=SC1091
source "$ROOT/bin/setup"
fail() { echo "FAIL: $*" >&2; exit 1; }
normalize_block_order() { :; }
configure_shell() { :; }

write_manifest() { mkdir -p "$(dirname "$MANIFEST_FILE")"; printf '%b' "$1" > "$MANIFEST_FILE"; }
fetch_manifest() { :; }

# install aggregates an early failure and continues to later success.
write_manifest '# module\ttarget\tmode\tsource\nfail\t~/fail\t0755\tx\nok\t~/ok\t0755\tx\n'
install_one() { [[ "$1" == ok ]]; }
if cmd_install fail ok >/dev/null 2>&1; then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || fail "mixed install failure was masked"

# file update aggregates an early failure and continues.
installed_hash_for() { echo tracked; }
install_one() { [[ "$1" == ok ]]; }
if cmd_update fail ok >/dev/null 2>&1; then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || fail "mixed update failure was masked"

# A script module may defer work that needs an interactive administrator
# prompt. Batch updates report it without failing the scheduled run.
write_manifest '# module\ttarget\tmode\tsource\ndefer\t~/defer\tscript\tx\n'
script_status_fields() { printf '%s\toutdated\tupdate available\told\tnew\t1\t\n' "$HOME/defer"; }
_script_update() { return 75; }
if output=$(cmd_update defer 2>&1); then rc=0; else rc=$?; fi
[[ $rc -eq 0 ]] || fail "deferred script update failed the command"
[[ "$output" == *'1 module(s) need an interactive update: defer'* ]] \
    || fail "deferred script update was not reported"
[[ "$output" != *'All modules up to date.'* ]] \
    || fail "deferred script update was reported as current"

# A module whose upstream is unreachable reports 'installed'/'unknown' on purpose,
# meaning it left what is on disk alone. That is not a failed run: counting a
# momentary network blip as failure is what let a real four-day outage hide in a
# nightly that was already red.
for unreachable in installed unknown; do
    write_manifest '# module\ttarget\tmode\tsource\nblip\t~/blip\tscript\tx\n'
    script_status_fields() { printf '%s\t'"$unreachable"'\tupstream unreachable\tv1\tv1\t1\t\n' "$HOME/blip"; }
    if output=$(cmd_update blip 2>&1); then rc=0; else rc=$?; fi
    [[ $rc -eq 0 ]] || fail "$unreachable module failed the run"
    [[ "$output" == *'1 module(s) could not be checked (upstream unreachable): blip'* ]] \
        || fail "$unreachable module was not reported as unchecked"
    [[ "$output" != *'could not be updated'* ]] \
        || fail "$unreachable module was counted as a failure"
    [[ "$output" != *'All modules up to date.'* ]] \
        || fail "$unreachable module was reported as current"
done

# A module that genuinely failed still turns the run red, so red keeps meaning
# that a human is needed -- this is the opencodex case.
write_manifest '# module\ttarget\tmode\tsource\nbroken\t~/broken\tscript\tx\n'
script_status_fields() { printf '%s\toutdated\tupdate available\told\tnew\t1\t\n' "$HOME/broken"; }
_script_update() { return 1; }
if output=$(cmd_update broken 2>&1); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || fail "a genuinely failed module did not fail the run"
[[ "$output" == *'1 module(s) could not be updated: broken'* ]] \
    || fail "a genuinely failed module was not named"

# An unreachable check alongside a real failure still fails, and each is counted
# under its own heading rather than merged.
write_manifest '# module\ttarget\tmode\tsource\nblip\t~/blip\tscript\tx\nbroken\t~/broken\tscript\tx\n'
script_status_fields() {
    if [[ "$1" == blip ]]; then printf '%s\tinstalled\tupstream unreachable\tv1\tv1\t1\t\n' "$HOME/blip"
    else printf '%s\toutdated\tupdate available\told\tnew\t1\t\n' "$HOME/broken"; fi
}
_script_update() { return 1; }
if output=$(cmd_update blip broken 2>&1); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || fail "a real failure was masked by an unchecked module"
[[ "$output" == *'could not be updated: broken'* ]] \
    || fail "the real failure was not named separately"
[[ "$output" == *'could not be checked (upstream unreachable): blip'* ]] \
    || fail "the unchecked module was not named separately"
# Both stubs go, not just the update one: a later test inheriting the status
# stub would silently read these fixtures' state instead of its own.
unset -f _script_update script_status_fields

# Explicit enable/disable aggregate, verify convergence, and reject toolonly.
SERVICE_MODULES='fail ok toolonly'
USER_SERVICE_MODULES='fail ok'
module_service_unit() { [[ "$1" == toolonly ]] && echo tool || echo "$1.timer"; }
module_enable_cmd() { echo "transition_cmd $1 enable"; }
module_disable_cmd() { echo "transition_cmd $1 disable"; }
transition_cmd() { return 0; }
module_is_active() {
    case "${DESIRED:-enable}:$1" in enable:ok|uninstall:fail) return 0 ;; disable:fail) return 0 ;; *) return 1 ;; esac
}
DESIRED=enable
if cmd_enable fail ok toolonly >/dev/null 2>&1; then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || fail "enable state failure/tool rejection was masked"
DESIRED=disable
if cmd_disable fail ok >/dev/null 2>&1; then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || fail "disable state failure was masked"

# Explicit uninstall retains a service whose disable does not converge, but
# continues and removes another selected module.
write_manifest '# module\ttarget\tmode\tsource\nfail\t~/fail\t0755\tx\nok\t~/ok\t0755\tx\n'
touch "$HOME/fail" "$HOME/ok"
SERVICE_MODULES='fail'
USER_SERVICE_MODULES='fail'
DESIRED=uninstall
uninstall_one() { rm -f "$(expand_path "$2")"; }
if cmd_uninstall fail ok >/dev/null 2>&1; then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || fail "uninstall pre-disable failure was masked"
[[ -e "$HOME/fail" ]] || fail "failed service disable did not retain target"
[[ ! -e "$HOME/ok" ]] || fail "failed service disable stopped later uninstall"

echo "explicit command outcome tests passed"
