#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fail() { echo "system-updates test failed: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file $1"; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected path $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 lacks: $2"; }

FIXTURE="$TEST_TMP/fixture"
FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$FIXTURE/etc" "$FIXTURE/etc/systemd/system" "$FIXTURE/etc/apt/apt.conf.d" \
    "$FIXTURE/var/lib/system-updates" "$FIXTURE/run/lock" "$FIXTURE/usr/local/libexec" \
    "$TEST_TMP/sysstate" "$FAKE_BIN"
LOG="$TEST_TMP/commands.log"
: > "$LOG"
export STUB_LOG="$LOG" STUB_STATE="$TEST_TMP/sysstate" STUB_SYSTEMD_DIR="$FIXTURE/etc/systemd/system"

cat > "$FAKE_BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
set -e
printf 'systemctl %s\n' "$*" >> "$STUB_LOG"
cmd=${1:-}; shift || true
case "$cmd" in
 cat) [[ -f "$STUB_SYSTEMD_DIR/$1" || -f "$STUB_STATE/$1.exists" ]] ;;
 is-enabled) cat "$STUB_STATE/$1.enabled" 2>/dev/null || { echo disabled; exit 1; } ;;
 is-active) cat "$STUB_STATE/$1.active" 2>/dev/null || { echo inactive; exit 3; } ;;
 show) echo 'Thu 2026-07-30 07:00:00 UTC' ;;
 daemon-reload|reboot) : ;;
 enable)
   now=0; runtime=0
   while [[ ${1:-} == -* ]]; do [[ $1 == --now ]] && now=1; [[ $1 == --runtime ]] && runtime=1; shift; done
   if [[ " $* " == *' system-updates.timer '* ]]; then
     if [[ ${STUB_FAIL_ENABLE:-0} == 1 ]]; then exit 1; fi
     if [[ ${STUB_FAIL_ENABLE:-0} == once && ! -e "$STUB_STATE/enable-failed-once" ]]; then
       touch "$STUB_STATE/enable-failed-once"
       exit 1
     fi
   fi
   for unit in "$@"; do [[ $runtime == 1 ]] && echo enabled-runtime > "$STUB_STATE/$unit.enabled" || echo enabled > "$STUB_STATE/$unit.enabled"; [[ $now == 1 ]] && echo active > "$STUB_STATE/$unit.active" || true; done ;;
 disable)
   now=0; runtime=0
   while [[ ${1:-} == -* ]]; do [[ $1 == --now ]] && now=1; [[ $1 == --runtime ]] && runtime=1; shift; done
   for unit in "$@"; do echo disabled > "$STUB_STATE/$unit.enabled"; [[ $now == 1 ]] && echo inactive > "$STUB_STATE/$unit.active" || true; done ;;
 start) for unit in "$@"; do echo active > "$STUB_STATE/$unit.active"; done ;;
 stop) for unit in "$@"; do echo inactive > "$STUB_STATE/$unit.active"; done ;;
 *) : ;;
esac
STUB
cat > "$FAKE_BIN/apt-get" <<'STUB'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "$STUB_LOG"
exit "${STUB_APT_RC:-0}"
STUB
cat > "$FAKE_BIN/apt-config" <<'STUB'
#!/usr/bin/env bash
printf 'apt-config %s\n' "$*" >> "$STUB_LOG"
if grep -q 'Automatic-Reboot "false"' "$STUB_APT_CONF/99-system-updates" 2>/dev/null; then echo "value='false'"; else echo "value='true'"; fi
STUB
cat > "$FAKE_BIN/unattended-upgrade" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$FAKE_BIN/dnf" <<'STUB'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >> "$STUB_LOG"
if [[ $* == *needs-restarting* ]]; then
  [[ ${STUB_DNF_CAPABLE:-1} == 1 ]] || exit 2
  [[ $* == *--help* ]] && { echo '  -r, --reboothint'; exit 0; }
  exit "${STUB_DNF_REBOOT_RC:-0}"
fi
exit "${STUB_DNF_RC:-0}"
STUB
cat > "$FAKE_BIN/flock" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_FLOCK_RC:-0}"
STUB
cat > "$FAKE_BIN/loginctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
 list-sessions) [[ ${STUB_SESSION:-none} == none ]] || echo '7 1000 user seat0 tty1' ;;
 show-session)
   case "${STUB_SESSION:-none}" in
     active) [[ $* == *' Class '* ]] && printf 'user\n' || printf 'active\n' ;;
     background) [[ $* == *' Class '* ]] && printf 'background\n' || printf 'active\n' ;;
     error) exit 1 ;;
   esac ;;
esac
STUB
chmod +x "$FAKE_BIN"/*
export PATH="$FAKE_BIN:/usr/bin:/bin"
export SYSTEM_UPDATES_ROOT="$FIXTURE" SYSTEM_UPDATES_TEST_MODE=1 SYSTEM_UPDATES_SOURCE_ONLY=1
export SYSTEM_UPDATES_SELF_PATH="$REPO_ROOT/bin/system-updates" STUB_APT_CONF="$FIXTURE/etc/apt/apt.conf.d"
# shellcheck disable=SC1090
source "$REPO_ROOT/bin/system-updates"

[[ $(root_owner_ids) == "$(id -u):$(id -g)" ]] || fail 'test-mode numeric ownership expectation is wrong'

# Distro selection and capability success/failure do not depend on host tools.
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$FIXTURE/etc/os-release"
[[ $(family_backend) == apt ]] || fail 'Ubuntu did not select Apt'
printf 'ID=fedora\nID_LIKE="rhel fedora"\n' > "$FIXTURE/etc/os-release"
[[ $(family_backend) == dnf ]] || fail 'Fedora did not select DNF'
STUB_DNF_CAPABLE=0; export STUB_DNF_CAPABLE
if backend_capable dnf; then fail 'DNF capability failure accepted'; fi
STUB_DNF_CAPABLE=1; export STUB_DNF_CAPABLE
backend_capable dnf || fail 'DNF capability success rejected'
printf 'ID=arch\n' > "$FIXTURE/etc/os-release"
[[ $(family_backend) == unsupported ]] || fail 'Arch was not unsupported'

# Static unit policy: only the root copy is executed; reboot timer never catches up.
stage="$TEST_TMP/stage"; stage_payloads "$stage"
assert_contains "$stage/system-updates.service" 'ExecStart=/usr/local/libexec/system-updates run'
assert_contains "$stage/system-updates-reboot.service" 'ExecStart=/usr/local/libexec/system-updates reboot-check'
assert_contains "$stage/system-updates.timer" 'RandomizedDelaySec=30m'
assert_contains "$stage/system-updates.timer" 'AccuracySec=1s'
assert_contains "$stage/system-updates-reboot.timer" 'OnCalendar=*-*-* 07:00:00'
assert_contains "$stage/system-updates-reboot.timer" 'Persistent=false'
! grep -Rq 'shutdown' "$stage" || fail 'global shutdown scheduling present'

# Exact legacy content is recognized; divergent content is preserved.
printf '%s\n' "$APT_LEGACY_CONTENT" > "$APT_LEGACY"
legacy_matches_exact || fail 'exact legacy content not recognized'
printf '%s\n' "$APT_LEGACY_CONTENT" '# local edit' > "$APT_LEGACY"
if legacy_matches_exact; then fail 'divergent legacy content recognized'; fi

# A capability-deficient DNF family fails before installing module artifacts.
printf 'ID=fedora\nID_LIKE=fedora\n' > "$FIXTURE/etc/os-release"
STUB_DNF_CAPABLE=0; export STUB_DNF_CAPABLE
if (cmd_enable >/dev/null 2>&1); then fail 'capability-deficient DNF enable succeeded'; fi
assert_absent "$ROOT_COPY"; assert_absent "$UPDATE_TIMER"; assert_absent "$REBOOT_TIMER"
STUB_DNF_CAPABLE=1; export STUB_DNF_CAPABLE

# Apt lifecycle: enable, effective reboot override, root-copy semantics, native timer state, idempotent disable.
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$FIXTURE/etc/os-release"
printf '%s\n' "$APT_LEGACY_CONTENT" > "$APT_LEGACY"
touch "$STUB_STATE/apt-daily-upgrade.timer.exists"
echo enabled > "$STUB_STATE/apt-daily-upgrade.timer.enabled"
echo active > "$STUB_STATE/apt-daily-upgrade.timer.active"
: > "$LOG"
cmd_enable >/dev/null
assert_file "$ROOT_COPY"
[[ ! -L "$ROOT_COPY" && $(stat -c %a "$ROOT_COPY") == 755 ]] || fail 'root copy is symlinked or wrong mode'
cmp -s "$ROOT_COPY" "$REPO_ROOT/bin/system-updates" || fail 'root copy differs from module source'
assert_file "$APT_CONFIG"
assert_absent "$APT_LEGACY"
apt_effective_reboot_false || fail 'effective Apt Automatic-Reboot is not false'
assert_contains "$TIMER_STATE_FILE" $'apt-daily-upgrade.timer\tenabled\tactive'
[[ $(cat "$STUB_STATE/apt-daily-upgrade.timer.enabled") == disabled ]] || fail 'native Apt install timer left enabled'
[[ $(cat "$STUB_STATE/apt-daily-upgrade.timer.active") == inactive ]] || fail 'native Apt install timer left active'
! grep -q 'apt-daily.timer' "$LOG" || fail 'metadata-only Apt timer was changed'
# Re-enabling refreshes module artifacts without forgetting the pre-module
# native timer state that disable must eventually restore.
cmd_enable >/dev/null
assert_contains "$TIMER_STATE_FILE" $'apt-daily-upgrade.timer\tenabled\tactive'
# A failed refresh restores the already-enabled module state, while keeping the
# displaced native timer disabled rather than accidentally re-enabling it.
rm -f "$STUB_STATE/enable-failed-once"
STUB_FAIL_ENABLE=once; export STUB_FAIL_ENABLE
if (cmd_enable >/dev/null 2>&1); then fail 'failed re-enable unexpectedly succeeded'; fi
STUB_FAIL_ENABLE=0; export STUB_FAIL_ENABLE
assert_file "$ROOT_COPY"; assert_file "$UPDATE_TIMER"; assert_file "$REBOOT_TIMER"
[[ $(cat "$STUB_STATE/system-updates.timer.enabled") == enabled \
    && $(cat "$STUB_STATE/system-updates.timer.active") == active ]] \
    || fail 'failed re-enable did not restore module timer state'
[[ $(cat "$STUB_STATE/apt-daily-upgrade.timer.enabled") == disabled \
    && $(cat "$STUB_STATE/apt-daily-upgrade.timer.active") == inactive ]] \
    || fail 'failed re-enable restored the displaced native timer too early'
assert_contains "$TIMER_STATE_FILE" $'apt-daily-upgrade.timer\tenabled\tactive'
: > "$LOG"; cmd_run
assert_contains "$LOG" 'apt-get update'
assert_contains "$LOG" 'full-upgrade'
assert_contains "$LAST_RUN_FILE" $'result\tsuccess'
cmd_disable >/dev/null
assert_absent "$ROOT_COPY"; assert_absent "$APT_CONFIG"; assert_absent "$UPDATE_TIMER"; assert_absent "$REBOOT_TIMER"
[[ $(cat "$STUB_STATE/apt-daily-upgrade.timer.enabled") == enabled ]] || fail 'native Apt enabled state not restored'
[[ $(cat "$STUB_STATE/apt-daily-upgrade.timer.active") == active ]] || fail 'native Apt active state not restored'
cmd_disable >/dev/null

# A divergent legacy file survives enable and is only effectively overridden.
printf '%s\n' "$APT_LEGACY_CONTENT" '# administrator edit' > "$APT_LEGACY"
cmd_enable >/dev/null 2>&1
assert_file "$APT_LEGACY"
cmd_disable >/dev/null

# DNF update scope and reboot probe semantics.
printf 'ID=fedora\nID_LIKE=fedora\n' > "$FIXTURE/etc/os-release"
mkdir -p "$STATE_DIR"; printf 'dnf\n' > "$BACKEND_FILE"
: > "$LOG"; STUB_DNF_RC=0 STUB_FLOCK_RC=0; export STUB_DNF_RC STUB_FLOCK_RC
cmd_run
assert_contains "$LOG" 'dnf -y --refresh upgrade'
assert_contains "$LAST_RUN_FILE" $'result\tsuccess'
STUB_DNF_REBOOT_RC=1; export STUB_DNF_REBOOT_RC
reboot_required dnf || fail 'DNF reboot-required rc=1 not recognized'
STUB_DNF_REBOOT_RC=0; export STUB_DNF_REBOOT_RC
if reboot_required dnf; then fail 'DNF reboot-required rc=0 misread'; fi

# Lock contention records parseable state and never calls the package manager.
: > "$LOG"; STUB_FLOCK_RC=1; export STUB_FLOCK_RC
if (cmd_run >/dev/null 2>&1); then fail 'update lock contention succeeded'; fi
assert_contains "$LAST_RUN_FILE" $'result\tcontention'
! grep -q '^dnf .*upgrade' "$LOG" || fail 'package manager ran despite lock contention'
STUB_FLOCK_RC=0; export STUB_FLOCK_RC

# A pre-created lock symlink is rejected before it can be opened or truncated.
rm -f "$LOCK_FILE"
printf 'lock target\n' > "$TEST_TMP/lock-target"
ln -s "$TEST_TMP/lock-target" "$LOCK_FILE"
if (cmd_run >/dev/null 2>&1); then fail 'lock-file symlink was accepted'; fi
[[ $(cat "$TEST_TMP/lock-target") == 'lock target' ]] || fail 'lock symlink target was modified'
rm -f "$LOCK_FILE"

# Reboot re-checks current sessions at 07:00, suppresses active/unknown users, and skips during update.
STUB_DNF_REBOOT_RC=1 STUB_SESSION=active; export STUB_DNF_REBOOT_RC STUB_SESSION
: > "$LOG"; cmd_reboot_check >/dev/null
! grep -q 'systemctl reboot' "$LOG" || fail 'active user did not suppress reboot'
STUB_SESSION=error; export STUB_SESSION
: > "$LOG"; cmd_reboot_check >/dev/null
! grep -q 'systemctl reboot' "$LOG" || fail 'unknown sessions did not fail safe'
STUB_SESSION=none; export STUB_SESSION
: > "$LOG"; cmd_reboot_check >/dev/null
assert_contains "$LOG" 'systemctl reboot'
STUB_FLOCK_RC=1; export STUB_FLOCK_RC
: > "$LOG"; cmd_reboot_check >/dev/null
! grep -q 'systemctl reboot' "$LOG" || fail 'active update did not suppress reboot'
STUB_FLOCK_RC=0; export STUB_FLOCK_RC

# Mid-enable systemctl failure rolls module artifacts back and restores native timer state.
rm -rf "$FIXTURE/etc/systemd/system" "$FIXTURE/usr/local/libexec" "$FIXTURE/var/lib/system-updates" "$FIXTURE/etc/apt/apt.conf.d"
mkdir -p "$FIXTURE/etc/systemd/system" "$FIXTURE/usr/local/libexec" "$FIXTURE/var/lib/system-updates" "$FIXTURE/etc/apt/apt.conf.d"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$FIXTURE/etc/os-release"
touch "$STUB_STATE/apt-daily-upgrade.timer.exists"
echo enabled > "$STUB_STATE/apt-daily-upgrade.timer.enabled"; echo active > "$STUB_STATE/apt-daily-upgrade.timer.active"
STUB_FAIL_ENABLE=1; export STUB_FAIL_ENABLE
if (cmd_enable >/dev/null 2>&1); then fail 'partial enable unexpectedly succeeded'; fi
assert_absent "$ROOT_COPY"; assert_absent "$APT_CONFIG"; assert_absent "$UPDATE_TIMER"; assert_absent "$REBOOT_TIMER"
[[ $(cat "$STUB_STATE/apt-daily-upgrade.timer.enabled") == enabled && $(cat "$STUB_STATE/apt-daily-upgrade.timer.active") == active ]] \
    || fail 'rollback did not restore native timer state'
STUB_FAIL_ENABLE=0; export STUB_FAIL_ENABLE

# Enable refuses to execute through or replace a symlink at the privileged copy path.
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$FIXTURE/etc/os-release"
printf 'do not replace\n' > "$TEST_TMP/symlink-target"
ln -s "$TEST_TMP/symlink-target" "$ROOT_COPY"
if (cmd_enable >/dev/null 2>&1); then fail 'root-copy symlink was accepted'; fi
[[ -L "$ROOT_COPY" ]] || fail 'rollback did not preserve the pre-existing root-copy symlink'
[[ $(cat "$TEST_TMP/symlink-target") == 'do not replace' ]] || fail 'root-copy symlink target was modified'
rm -f "$ROOT_COPY"

# Unsupported enable fails clearly without changing the system.
printf 'ID=arch\n' > "$FIXTURE/etc/os-release"
if cmd_enable >/dev/null; then fail 'unsupported enable reported success'; fi
assert_absent "$ROOT_COPY"; assert_absent "$UPDATE_TIMER"

echo 'system-updates tests passed'
