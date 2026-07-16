#!/usr/bin/env bash
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

# Explicit enable/disable aggregate, verify convergence, and reject service-ctl.
SERVICE_MODULES='fail ok service-ctl'
USER_SERVICE_MODULES='fail ok'
module_service_unit() { [[ "$1" == service-ctl ]] && echo tool || echo "$1.timer"; }
module_enable_cmd() { echo "transition_cmd $1 enable"; }
module_disable_cmd() { echo "transition_cmd $1 disable"; }
transition_cmd() { return 0; }
module_is_active() {
    case "${DESIRED:-enable}:$1" in enable:ok|uninstall:fail) return 0 ;; disable:fail) return 0 ;; *) return 1 ;; esac
}
DESIRED=enable
if cmd_enable fail ok service-ctl >/dev/null 2>&1; then rc=0; else rc=$?; fi
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
