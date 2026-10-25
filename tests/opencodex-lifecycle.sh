#!/usr/bin/env zsh
# The opencodex module installs only the picker, and hands a machine's old
# setup-managed OpenCodex runtime over to fleet: success, a busy proxy putting
# it off, and a failed `fleet install ocx` leaving the old runtime serving.
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export OPENCODEX_LAUNCHER_SOURCE="$ROOT/files/opencodex"
export FLEET_BIN="$TEST_TMP/stubs/fleet"
export OPENCODEX_IDLE_WAIT=0 OPENCODEX_ACTIVATE_WAIT=0
# A pinned PATH: nothing here may reach the real ocx, npm, fleet or systemctl.
export PATH="$TEST_TMP/stubs:$TEST_TMP/npm/bin:/usr/bin:/bin"
LOG="$TEST_TMP/fleet.log"
LEGACY="$HOME/.local/libexec/opencodex"
LINK="$HOME/.local/bin/ocx"
NEW_OCX="$TEST_TMP/npm/bin/ocx"
DROPIN="$HOME/.config/systemd/user/opencodex-proxy.service.d/50-stop-timeout.conf"
mkdir -p "$HOME/.local/bin" "$HOME/.opencodex" "$TEST_TMP/stubs" "$TEST_TMP/proxy/api/system" "${NEW_OCX:h}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# A stand-in proxy: static /healthz and turn count, on a port of its own.
print -r -- '{"status":"ok"}' > "$TEST_TMP/proxy/healthz"
turns() { print -r -- "{\"activeTurnCount\":$1}" > "$TEST_TMP/proxy/api/system/memory"; }
turns 0
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server --bind 127.0.0.1 --directory "$TEST_TMP/proxy" "$port" >/dev/null 2>&1 &
proxy_pid=$!
trap 'kill $proxy_pid 2>/dev/null; rm -rf "$TEST_TMP"' EXIT
print -r -- "{\"port\":$port}" > "$HOME/.opencodex/runtime-port.json"
print -r -- admin > "$HOME/.opencodex/admin-api-token"
for _ in {1..50}; do curl -fs "http://127.0.0.1:$port/healthz" >/dev/null && break; sleep 0.1; done

# fleet: `install ocx` installs the new ocx, whose service then records it,
# unless fleet-fails exists (exit 1) or service-stays exists (exit 0 without
# rewriting the service); it logs whether the old link was still there. With
# local-prefix, npm's global prefix is ~/.local, so the new ocx is ~/.local/bin/ocx
# too. With cold-start, the new proxy answers only after `ocx service` gave up.
PACKAGE="$HOME/.local/lib/node_modules/@bitkyc08/opencodex"
cat > "$FLEET_BIN" <<EOF
#!/bin/sh
echo "\$*" >> "$LOG"
[ "\$1" = install ] || exit 0
[ -e "$LINK" ] && echo "link present" >> "$LOG"
[ -e "$TEST_TMP/fleet-fails" ] && exit 1
[ -e "$TEST_TMP/service-stays" ] && exit 0
if [ -e "$TEST_TMP/local-prefix" ]; then
    mkdir -p "$PACKAGE/bin" "$PACKAGE/src/cli" && printf '#!/bin/sh\n' > "$PACKAGE/bin/ocx"
    chmod +x "$PACKAGE/bin/ocx" && : > "$PACKAGE/src/cli/index.ts" && ln -s "$PACKAGE/bin/ocx" "$LINK"
    printf '{"launcherPath":"%s","cliPath":"%s"}' "$LINK" "$PACKAGE/src/cli/index.ts" > "$HOME/.opencodex/service-state.json"
    exit 0
fi
printf '#!/bin/sh\n' > "$NEW_OCX" && chmod +x "$NEW_OCX"
printf '{"launcherPath":"%s"}' "$NEW_OCX" > "$HOME/.opencodex/service-state.json"
if [ -e "$TEST_TMP/cold-start" ]; then
    rm -f "$TEST_TMP/proxy/healthz"
    (sleep 3; echo '{"status":"ok"}' > "$TEST_TMP/proxy/healthz") >/dev/null 2>&1 &
    exit 1
fi
EOF
chmod +x "$FLEET_BIN"

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/opencodex.sh"

expect_status() {
    local expected_rc="$1" expected_word="$2" output rc=0
    output=$(status) || rc=$?
    [[ "$rc" == "$expected_rc" ]] || fail "status returned $rc, expected $expected_rc: $output"
    [[ "$output" == *"$expected_word"* ]] || fail "status omitted $expected_word: $output"
}

# What the old module left on a machine.
legacy_machine() {
    mkdir -p "$LEGACY/node_modules/.bin" "$HOME/.config/opencodex" "${DROPIN:h}"
    print -r -- '#!/bin/sh' > "$LEGACY/node_modules/.bin/ocx"
    chmod +x "$LEGACY/node_modules/.bin/ocx"
    ln -sfn "$LEGACY/node_modules/.bin/ocx" "$LINK"
    printf '{"launcherPath":"%s","bunPath":"%s/node_modules/bun/bin/bun.exe"}' "$LINK" "$LEGACY" \
        > "$HOME/.opencodex/service-state.json"
    print -r -- '{}' > "$HOME/.config/opencodex/managed-profiles.json"
    : > "$HOME/.opencodex/setup-live-applied"
    print -r -- 'old launcher' > "$BIN"
    printf '[Service]\nTimeoutStopSec=330\n' > "$DROPIN"
    rm -f "$NEW_OCX" "$LOG"
}

old_runtime_intact() {
    [[ -d "$LEGACY" && "$(readlink "$LINK")" == "$LEGACY/node_modules/.bin/ocx" ]] \
        || fail "$1: the old runtime or its ocx link is gone"
    [[ "$(<"$BIN")" == 'old launcher' ]] || fail "$1: the old launcher was replaced before the hand-over"
    [[ -e "$HOME/.config/opencodex/managed-profiles.json" ]] || fail "$1: old files were cleaned up early"
}

# --- a machine without the old runtime: just the picker ----------------------
install >/dev/null
cmp -s "$ROOT/files/opencodex" "$BIN" || fail "install did not put the launcher in place"
[[ -x "$BIN" ]] || fail "the launcher is not executable"
[[ ! -e "$LOG" ]] || fail "install ran fleet with nothing to hand over"
expect_status 0 current
print '# drift' >> "$BIN"
expect_status 1 outdated
update >/dev/null
expect_status 0 current

# --- a busy proxy puts the hand-over off and changes nothing ----------------
legacy_machine
expect_status 1 legacy-runtime
turns 1
update 2>"$TEST_TMP/err" || fail "a deferred hand-over failed the update"
grep -q 'put off to the next run' "$TEST_TMP/err" || fail "a deferred hand-over did not say so"
[[ ! -e "$LOG" ]] || fail "fleet ran while the proxy was busy"
old_runtime_intact "busy proxy"
expect_status 1 legacy-runtime
turns 0

# --- a failed new install keeps the old runtime serving ---------------------
touch "$TEST_TMP/fleet-fails"
if update 2>"$TEST_TMP/err"; then fail "a failed fleet install reported success"; fi
grep -q 'old OpenCodex runtime keeps serving' "$TEST_TMP/err" || fail "a failed hand-over did not say so"
grep -qx 'install ocx' "$LOG" || fail "the hand-over never asked fleet to install ocx"
! grep -q 'link present' "$LOG" || fail "fleet saw the old ocx link, so it would read ocx as installed"
old_runtime_intact "failed install"
rm "$TEST_TMP/fleet-fails"

# An install that leaves ocx's service on the old runtime is no hand-over either.
touch "$TEST_TMP/service-stays"
if update 2>/dev/null; then fail "a service still on the old runtime counted as handed over"; fi
old_runtime_intact "service on old runtime"

# A retry after an attempt that installed the package but never rewrote the
# service: fleet calls ocx already installed, so the hand-over repairs it.
cat > "$NEW_OCX" <<EOF
#!/bin/sh
echo "ocx \$*" >> "$LOG"
[ "\$1" = service ] && printf '{"launcherPath":"%s"}' "$NEW_OCX" > "$HOME/.opencodex/service-state.json"
exit 0
EOF
chmod +x "$NEW_OCX"
rm -f "$LOG"
update >/dev/null || fail "a retry with ocx already installed did not repair its service"
[[ "$(<"$LOG")" == $'install ocx\nocx service\nsync --pull' ]] \
    || fail "the retry did not repair the service through the installed ocx: $(<"$LOG")"
[[ ! -e "$LEGACY" ]] && cmp -s "$ROOT/files/opencodex" "$BIN" || fail "the retry left the old runtime"
rm "$TEST_TMP/service-stays"
legacy_machine

# --- the hand-over -----------------------------------------------------------
rm -f "$LOG"
update >/dev/null || fail "the hand-over failed"
[[ "$(<"$LOG")" == $'install ocx\nsync --pull' ]] || fail "the hand-over did not install ocx then pull-sync: $(<"$LOG")"
[[ ! -e "$LEGACY" && ! -L "$LINK" ]] || fail "the old runtime or its ocx link survived the hand-over"
[[ ! -e "$HOME/.config/opencodex/managed-profiles.json" && ! -e "$HOME/.opencodex/setup-live-applied" ]] \
    || fail "the old launcher's files survived the hand-over"
cmp -s "$ROOT/files/opencodex" "$BIN" || fail "the hand-over did not install the picker"
[[ -f "$DROPIN" ]] || fail "the hand-over removed the stop-timeout drop-in fleet's proxy still needs"
expect_status 0 current
rm -f "$LOG"
update >/dev/null
[[ ! -e "$LOG" ]] || fail "a second update ran fleet again"

# --- a cold start outlasting `ocx service` still hands over -----------------
legacy_machine
touch "$TEST_TMP/cold-start"
OPENCODEX_ACTIVATE_WAIT=15 update >/dev/null 2>"$TEST_TMP/err" || fail "a late-answering proxy failed the hand-over"
grep -q 'fleet install ocx exited 1; waiting for the proxy' "$TEST_TMP/err" || fail "the install's exit 1 went unmentioned"
[[ ! -e "$LEGACY" ]] && cmp -s "$ROOT/files/opencodex" "$BIN" || fail "a late-answering proxy left the old runtime"
rm "$TEST_TMP/cold-start"

# --- an npm prefix of ~/.local puts the new ocx where the old link was ------
legacy_machine
touch "$TEST_TMP/local-prefix"
update >/dev/null || fail "a new ocx at ~/.local/bin/ocx read as the old runtime"
[[ ! -e "$LEGACY" && "$(realpath "$LINK")" == "$(realpath "$PACKAGE/bin/ocx")" ]] \
    || fail "the ~/.local hand-over left the old runtime or lost the new ocx"
rm "$TEST_TMP/local-prefix"

# --- uninstall ---------------------------------------------------------------
# Only the picker goes; fleet's ocx and the drop-in stay.
uninstall >/dev/null
[[ ! -e "$BIN" ]] || fail "uninstall left the launcher"
[[ -f "$DROPIN" && -x "$LINK" ]] || fail "uninstall touched fleet's ocx"
expect_status 2 uninstalled
# An old runtime is handed over rather than left orphaned.
legacy_machine
uninstall >/dev/null || fail "uninstall did not hand the old runtime over"
[[ ! -e "$LEGACY" && ! -e "$BIN" ]] || fail "uninstall left the old runtime or the launcher"
grep -qx 'install ocx' "$LOG" || fail "uninstall did not hand the old runtime to fleet"

echo "opencodex lifecycle tests passed"
