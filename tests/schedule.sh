#!/usr/bin/env zsh
# Tests bin/schedule with a stubbed systemctl: install/status/uninstall
# plumbing across user and system scopes, plus extra-lines injection.
set -euo pipefail

# Self-locate the repo root. When run through a wrapper (e.g. an agent
# harness) $0 and ${%x} can be the interpreter name rather than this
# script path, so resolve by searching candidate anchors for bin/schedule.
ROOT=""
for _cand in "${0:A:h:h}" "${${(%):-%x}:A:h:h}" "$(pwd)" "$(pwd)/.."; do
    if [[ -f "$_cand/bin/schedule" ]]; then ROOT="$(cd "$_cand" && pwd)"; break; fi
done
unset _cand
[[ -n "$ROOT" ]] || { echo "schedule test: could not locate repo root" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export SCHEDULE_USER_DIR="$TMP/user-units"
export SCHEDULE_SYSTEM_DIR="$TMP/system-units"
mkdir -p "$HOME" "$SCHEDULE_USER_DIR" "$SCHEDULE_SYSTEM_DIR" "$TMP/bin"
LOG="$TMP/systemctl.log"; : > "$LOG"
export LOG

fail() { echo "schedule test failed: $*" >&2; exit 1; }

cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$LOG"
if [[ "${1:-}" == "--user" ]]; then shift; fi
cmd="${1:-}"; shift || true
case "$cmd" in
  daemon-reload) : ;;
  enable|disable) exit 0 ;;
  is-enabled) echo enabled; exit 0 ;;
  is-active) echo active; exit 0 ;;
  show) echo "Sat 2026-09-13 09:00:00 KST" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

SCHEDULE="$ROOT/bin/schedule"

# render emits the shared skeleton.
"$SCHEDULE" render timer user demo "Demo" "daily" > "$TMP/rout" 2> "$TMP/rerr"; echo "HRC=$?"; echo "OUT:"; cat "$TMP/rout"; echo "ERR:"; cat "$TMP/rerr"; grep -q "OnCalendar=daily" "$TMP/rout" \
    || fail "render timer omitted OnCalendar"
"$SCHEDULE" render timer user demo "Demo" "daily" | grep -q "WantedBy=timers.target" \
    || fail "render timer omitted Install section"

# install writes both units to the scope dir and runs the enable dance.
printf "Nice=19\n" > "$TMP/svc-extra"
printf "Persistent=true\n" > "$TMP/timer-extra"
"$SCHEDULE" install-timer user demo "Demo job" "/usr/bin/demo run" "*-*-* 09:00:00" \
    "$TMP/svc-extra" "$TMP/timer-extra" >/dev/null || fail "install-timer failed"
[[ -f "$SCHEDULE_USER_DIR/demo.service" ]] || fail "service not written"
[[ -f "$SCHEDULE_USER_DIR/demo.timer" ]] || fail "timer not written"
grep -q "Nice=19" "$SCHEDULE_USER_DIR/demo.service" || fail "service extra lines dropped"
grep -q "Persistent=true" "$SCHEDULE_USER_DIR/demo.timer" || fail "timer extra lines dropped"
grep -q "systemctl --user daemon-reload" "$LOG" || fail "user daemon-reload missing"
grep -q "systemctl --user enable --now demo.timer" "$LOG" || fail "user enable --now missing"

# status reports enabled/active and exits 0.
"$SCHEDULE" status user demo >/dev/null || fail "status returned nonzero for enabled+active"
"$SCHEDULE" status user demo | grep -q "enabled/active" || fail "status output malformed"

# system scope uses no --user flag.
: > "$LOG"
"$SCHEDULE" install-timer system kernel-simmer "Kernel" "/usr/local/bin/kernel-simmer check" "weekly" \
    >/dev/null || fail "system install-timer failed"
[[ -f "$SCHEDULE_SYSTEM_DIR/kernel-simmer.timer" ]] || fail "system timer not written"
grep -q "^systemctl daemon-reload" "$LOG" || fail "system daemon-reload should not use --user"
grep -q "^systemctl enable --now kernel-simmer.timer" "$LOG" || fail "system enable should not use --user"

# uninstall removes the units and reloads.
"$SCHEDULE" uninstall-timer user demo >/dev/null || fail "uninstall-timer failed"
[[ ! -f "$SCHEDULE_USER_DIR/demo.timer" ]] || fail "timer not removed"
[[ ! -f "$SCHEDULE_USER_DIR/demo.service" ]] || fail "service not removed"

echo "schedule tests passed"
