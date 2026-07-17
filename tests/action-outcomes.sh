#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" SETUP_SOURCE_ONLY=1
mkdir -p "$HOME/.local/bin" "$XDG_STATE_HOME/setup"
# shellcheck disable=SC1091
source "$ROOT/bin/setup"

fail() { echo "FAIL: $*" >&2; exit 1; }
managed_picker() { echo fake-picker; }
fetch_manifest() { printf '# module\ttarget\tmode\tsource\n' > "$MANIFEST_FILE"; }
fetch_checksums() { :; }
fake-picker() { cat >/dev/null; return 1; }
cmd_reconfigure
confirm_action() { return 0; }
normalize_block_order() { :; }
delim=$'\x1f'
env_summary=test

# service-ctl is an installed tool, never an actionable service. In a mixed
# selection it must not create an Enable candidate that suppresses Disable for
# an actually active service.
snapshot=(
  "service-ctl"$'\t''~/.local/bin/service-ctl'$'\t''0755'$'\t''bin/service-ctl'$'\t''current'$'\t''1'$'\t''0'$'\t''0'$'\t''tool'
  "backup"$'\t''~/.local/bin/backup'$'\t''0755'$'\t''bin/backup'$'\t''current'$'\t''1'$'\t''1'$'\t''1'$'\t''active'
)
selected_modules=(service-ctl backup)
[[ $(eligible_count enable) -eq 0 ]] || fail "service-ctl tool became enable-eligible"
[[ $(eligible_count disable) -eq 1 ]] || fail "active service was not disable-eligible"
picker_fixture="$TMP/picker-fixture"
mkdir -p "$picker_fixture"
SETUP_PICKER_SNAPSHOT_FILE="$picker_fixture/snapshot.tsv"
SETUP_PICKER_SELECTION_FILE="$picker_fixture/selected"
SETUP_PICKER_DELIM=$'\x1f'
SETUP_PICKER_DETAIL_HEADER='module local service remote status'
printf '%s\n' "${snapshot[@]}" > "$SETUP_PICKER_SNAPSHOT_FILE"
printf '%s\n' "${selected_modules[@]}" > "$SETUP_PICKER_SELECTION_FILE"
rows=$(_setup_picker_render)
[[ "$rows" == *"Disable 1"* ]] || fail "tool suppressed contextual Disable action"
[[ "$rows" != *"Install 0"* && "$rows" != *"Update 0"* && "$rows" != *"Enable 0"* ]] \
    || fail "renderer surfaced a zero-count action"

assert_summary() {
    local action="$1" expected="$2" output rc
    if output=$(run_module_action "$action" 2>&1); then rc=0; else rc=$?; fi
    [[ $rc -ne 0 ]] || fail "$action failure returned success"
    [[ "$output" == *"$expected"* ]] || fail "$action summary mismatch: $output"
    [[ "$output" == *"Failed: $action fail"* ]] || fail "$action did not visibly name failed module"
}

# install continues after one failure.
snapshot=(
  "fail"$'\t''~/fail'$'\t''0755'$'\t''x'$'\t''uninstalled'$'\t''0'$'\t''0'$'\t''0'$'\t''x'
  "ok"$'\t''~/ok'$'\t''0755'$'\t''x'$'\t''uninstalled'$'\t''0'$'\t''0'$'\t''0'$'\t''x'
)
selected_modules=(fail ok)
install_one() { [[ "$1" == ok ]]; }
assert_summary install 'Install: attempted=2 succeeded=1 failed=1 skipped=0'

# update and reinstall report actual command failures and continue.
snapshot=(
  "fail"$'\t''~/fail'$'\t''script'$'\t''x'$'\t''outdated'$'\t''1'$'\t''0'$'\t''0'$'\t''x'
  "ok"$'\t''~/ok'$'\t''script'$'\t''x'$'\t''outdated'$'\t''1'$'\t''0'$'\t''0'$'\t''x'
)
selected_modules=(fail ok)
_script_update() { [[ "$1" == ok ]]; }
assert_summary update 'Update: attempted=2 succeeded=1 failed=1 skipped=0'
install_one() { [[ "$1" == ok ]]; }
assert_summary reinstall 'Reinstall: attempted=2 succeeded=1 failed=1 skipped=0'

# A nominally successful uninstall that retains a locally modified file counts
# as failed, while another selected module still proceeds.
touch "$HOME/fail" "$HOME/ok"
snapshot=(
  "fail"$'\t''~/fail'$'\t''0755'$'\t''x'$'\t''modified'$'\t''1'$'\t''0'$'\t''0'$'\t''x'
  "ok"$'\t''~/ok'$'\t''0755'$'\t''x'$'\t''current'$'\t''1'$'\t''0'$'\t''0'$'\t''x'
)
selected_modules=(fail ok)
uninstall_one() { [[ "$1" == ok ]] && rm -f "$HOME/ok"; return 0; }
assert_summary uninstall 'Uninstall: attempted=2 succeeded=1 failed=1 skipped=0'

# Service failures are visible, counted, continue across the subset, and make
# the helper fail overall.
snapshot=(
  "fail"$'\t''~/fail'$'\t''0755'$'\t''x'$'\t''current'$'\t''1'$'\t''1'$'\t''0'$'\t''x'
  "ok"$'\t''~/ok'$'\t''0755'$'\t''x'$'\t''current'$'\t''1'$'\t''1'$'\t''0'$'\t''x'
)
selected_modules=(fail ok)
USER_SERVICE_MODULES='fail ok'
module_enable_cmd() { echo "service_result $1"; }
service_result() { return 0; }
module_is_active() { [[ "$1" == ok ]]; }
if output=$(run_service_action enable 2>&1); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || fail "service failure returned success"
[[ "$output" == *'Enable: attempted=2 succeeded=1 failed=1 skipped=0'* ]] || fail "service summary mismatch: $output"
[[ "$output" == *'Failed: enable fail'* ]] || fail "zero-return/no-state-change service failure was not visible"

# A service that cannot be disabled must retain its target, while another
# selected module still uninstalls.
touch "$HOME/fail" "$HOME/ok"
snapshot=(
  "fail"$'\t''~/fail'$'\t''0755'$'\t''x'$'\t''current'$'\t''1'$'\t''1'$'\t''1'$'\t''x'
  "ok"$'\t''~/ok'$'\t''0755'$'\t''x'$'\t''current'$'\t''1'$'\t''0'$'\t''0'$'\t''x'
)
selected_modules=(fail ok)
USER_SERVICE_MODULES='fail'
is_service_module() { [[ "$1" == fail ]]; }
module_service_unit() { echo fail.timer; }
module_disable_cmd() { echo disable_result; }
disable_result() { return 1; }
module_is_active() { [[ "$1" == fail ]]; }
uninstall_one() { rm -f "$(expand_path "$2")"; }
if output=$(run_module_action uninstall 2>&1); then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || fail "pre-disable failure returned success"
[[ -e "$HOME/fail" ]] || fail "pre-disable failure did not retain service target"
[[ ! -e "$HOME/ok" ]] || fail "pre-disable failure stopped later selected uninstall"
[[ "$output" == *'Failed: disable fail before uninstall; target retained'* ]] || fail "pre-disable failure was not visible"
[[ "$output" == *'Uninstall: attempted=2 succeeded=1 failed=1 skipped=0'* ]] || fail "pre-disable summary mismatch: $output"

# Canceling an individual submenu returns to the existing snapshot instead of
# reprobeing module status before reopening the main picker.
fetch_manifest() {
    cat > "$MANIFEST_FILE" <<'EOF'
# module	target	mode	source
cancel-probe	~/cancel-probe	0755	x
EOF
}
printf '0\n' > "$TMP/status-probe-count"
file_status_fields() {
    local n=$(( $(cat "$TMP/status-probe-count") + 1 ))
    printf '%s\n' "$n" > "$TMP/status-probe-count"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$HOME/cancel-probe" uninstalled 'not installed' - x 0 x
}
printf '0\n' > "$TMP/picker-count"
fake-picker() {
    cat >/dev/null
    local n=$(( $(cat "$TMP/picker-count") + 1 )) d=$'\x1f'
    printf '%s\n' "$n" > "$TMP/picker-count"
    case "$n" in
      1) printf 'module%scancel-probe%sdetail\n' "$d" "$d" ;;
      2) printf 'action%scancel%sCancel\n' "$d" "$d" ;;
      *) return 1 ;;
    esac
}
cmd_reconfigure >/dev/null
[[ $(cat "$TMP/status-probe-count") -eq 1 ]] \
    || fail "canceling an individual submenu refreshed remote status"

# cmd_reconfigure remembers an action failure across redraw/refresh and returns
# it only after the picker exits (Esc/abort).
fetch_manifest() {
    cat > "$MANIFEST_FILE" <<'EOF'
# module	target	mode	source
fail	~/fail	0755	x
EOF
}
file_status_fields() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$HOME/fail" uninstalled 'not installed' - x 0 x; }
fetch_checksums() { :; }
printf '0\n' > "$TMP/picker-count"
fake-picker() {
    cat >/dev/null
    local n=$(( $(cat "$TMP/picker-count") + 1 )) d=$'\x1f'
    printf '%s\n' "$n" > "$TMP/picker-count"
    case "$n" in
      1)
          _setup_picker_transform checkbox fail >/dev/null
          printf 'action%sinstall%sInstall 1\n' "$d" "$d"
          ;;
      *) return 1 ;;
    esac
}
install_one() { return 1; }
if cmd_reconfigure >/dev/null 2>&1; then rc=0; else rc=$?; fi
[[ $rc -ne 0 ]] || fail "failed action followed by Esc returned success"

echo "action outcome tests passed"
