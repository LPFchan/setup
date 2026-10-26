#!/usr/bin/env zsh
# The handover from setup to fleet, which lives in LPFchan/auth (its own tests
# cover fleet's installer): a machine that had only fleet loses setup, one with
# other modules keeps setup without fleet and auth, and a timer that does not
# come on hands nothing over. The handover runs under the setup binary from
# before fleet stood on its own, which updates itself at the end of the pass
# and finishes under the new one.
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo "fleet standalone tests skipped (Linux only)"; exit 0; }
ROOT=${0:A:h:h}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { print -u2 -- "FAIL: $*"; exit 1; }

# A systemctl that records its calls and reports every timer on, or fails
# everything while $TMP/no-systemd exists. No harness or real tool on PATH.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/sh
echo "$*" >> "$TMP/systemctl.log"
[ -e "$TMP/no-systemd" ] && exit 1
[ "$1" = --user ] && shift
case "$1" in is-enabled) echo enabled ;; is-active) echo active ;; esac
exit 0
SH
chmod +x "$TMP/bin/systemctl"
export TMP PATH="$TMP/bin:/usr/bin:/bin" SHELL=/bin/zsh
unset SOURCE_URL LINUX_SETUP_SOURCE_URL FLEET_SOURCE_URL XDG_STATE_HOME XDG_CONFIG_HOME DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR=/nonexistent

# A source tree like the repo, with a catalog of setup, schedule, auth, fleet
# and one module of the operator's own choosing.
SRC="$TMP/src"
mkdir -p "$SRC/bin" "$SRC/files" "$SRC/lib"
cp "$ROOT/bin/setup" "$ROOT/bin/schedule" "$SRC/bin/"
cp "$ROOT/lib/script-helpers.sh" "$SRC/lib/"
for name in fleet.sh auth.sh resume; do
    cp "$ROOT/files/$name" "$SRC/files/"
done
grep -E '^(# module|setup|schedule|auth|fleet|resume)\b' "$ROOT/manifest.tsv" \
    | awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "setup" { $8 = "" } { print }' > "$SRC/manifest.tsv"

# A stand-in for what Auth serves at /fleet: an installer that puts fleet and
# auth in place and turns fleet's timer on, which fails while systemd does.
FLEETSRC="$TMP/fleet-src"
mkdir -p "$FLEETSRC"
cat > "$FLEETSRC/install.sh" <<'SH'
set -e
mkdir -p "$HOME/.local/bin"
cp "$SOURCE_URL/fleet" "$SOURCE_URL/auth" "$HOME/.local/bin/"
systemctl --user enable --quiet fleet-sync.timer
SH
printf '#!/bin/sh
[ "$1 $2" = "schedule status" ] && exec systemctl --user is-enabled fleet-sync.timer
' > "$FLEETSRC/fleet"
printf '#!/bin/sh
' > "$FLEETSRC/auth"
chmod +x "$FLEETSRC/fleet" "$FLEETSRC/auth"
export FLEET_SOURCE_URL="$FLEETSRC"
printf 'ssh-ed25519 AAAAOwner owner\n' > "$TMP/owner.keys"
export SETUP_OWNER_KEYS_URL="file://$TMP/owner.keys"

fresh_home() {
    export HOME="$TMP/home-$1"
    mkdir -p "$HOME/.local/bin"
    : > "$TMP/systemctl.log"
}
sha() { sha256sum "$1" | cut -d' ' -f1; }
state_has() { grep -q "^$1"$'\t' "$HOME/.local/state/setup/script-state.tsv" 2>/dev/null; }
installed_payload() {
    cmp -s "$HOME/.local/bin/fleet" "$FLEETSRC/fleet" && [[ -x "$HOME/.local/bin/auth" ]]
}

# --- a machine setup brought fleet to, under the old setup binary --------
# What `setup install fleet` left before: fleet and auth in setup's state,
# auth and schedule as its dependencies, setup's own nightly through the
# schedule helper, and the helper-made fleet timer.
# 231e45d: the last setup from before fleet stood on its own.
git -C "$ROOT" show 231e45d:bin/setup > "$TMP/setup.old" || fail "needs the repository history for the old setup"
setup_machine() {
    fresh_home "$1"
    local state="$HOME/.local/state/setup" units="$HOME/.config/systemd/user"
    mkdir -p "$state" "$units"
    install -m 0755 "$TMP/setup.old" "$HOME/.local/bin/setup"
    install -m 0755 "$ROOT/bin/schedule" "$HOME/.local/bin/schedule"
    printf '%s\t%s\t%s\n' "$HOME/.local/bin/setup" "$(sha "$TMP/setup.old")" "$(sha "$TMP/setup.old")" \
        "$HOME/.local/bin/schedule" "$(sha "$ROOT/bin/schedule")" "$(sha "$ROOT/bin/schedule")" > "$state/installed.tsv"
    printf 'auth\tauth\tx\tx\nfleet\tfleet\tx\tx\n' > "$state/script-state.tsv"
    printf 'auth\nschedule\n' > "$state/dependency-installed.txt"
    printf '[Timer]\n' > "$units/setup-update.timer"; printf '[Service]\n' > "$units/setup-update.service"
    printf '[Timer]\n' > "$units/fleet-sync.timer"; printf '[Service]\n' > "$units/fleet-sync.service"
    printf 'print("old fleet")\n' > "$HOME/.local/bin/fleet"; chmod +x "$HOME/.local/bin/fleet"
    printf '# >>> setup:path >>>\n# <<< setup:path <<<\n' > "$HOME/.zshenv"
}
run_setup() {
    LINUX_SETUP_SOURCE_URL="file://$SRC" zsh "$HOME/.local/bin/setup" --batch update >"$TMP/out" 2>&1
}

# Only fleet: setup hands fleet over, then removes its timer, the helper it
# installed for fleet, itself and its state.
setup_machine only-fleet
run_setup || { cat "$TMP/out"; fail "update on a fleet-only machine"; }
installed_payload || { cat "$TMP/out"; fail "handover left out part of the payload"; }
grep -q 'Restarting setup' "$TMP/out" || fail "the old setup did not hand the pass to the new one"
for gone in .local/bin/setup .local/bin/schedule .local/state/setup .config/systemd/user/setup-update.timer; do
    [[ ! -e "$HOME/$gone" ]] || { cat "$TMP/out"; fail "$gone left behind on a fleet-only machine"; }
done
grep -q 'setup:path' "$HOME/.zshenv" || fail "PATH block removed with setup"

# fleet plus a module the operator chose: setup stays, without fleet or auth.
setup_machine with-resume
install -m 0755 "$ROOT/files/resume" "$HOME/.local/bin/resume"
printf '%s\t%s\t%s\n' "$HOME/.local/bin/resume" "$(sha "$ROOT/files/resume")" "$(sha "$ROOT/files/resume")" \
    >> "$HOME/.local/state/setup/installed.tsv"
run_setup || { cat "$TMP/out"; fail "update on a machine with other modules"; }
installed_payload || fail "handover left out part of the payload"
cmp -s "$HOME/.local/bin/setup" "$ROOT/bin/setup" || fail "setup removed or not updated though another module needs it"
state_has fleet && fail "setup still manages fleet"
state_has auth && fail "setup still manages auth"
[[ -x "$HOME/.local/bin/resume" && -x "$HOME/.local/bin/schedule" ]] || fail "setup's modules lost"
[[ -e "$HOME/.config/systemd/user/setup-update.timer" ]] || fail "setup's own timer removed"
# From now on setup leaves fleet alone: the next update runs no installer.
: > "$TMP/systemctl.log"
run_setup || { cat "$TMP/out"; fail "second update"; }
grep -q 'fleet-sync' "$TMP/systemctl.log" && fail "setup touched fleet after the handover"
LINUX_SETUP_SOURCE_URL="file://$SRC" zsh "$HOME/.local/bin/setup" status fleet 2>/dev/null | grep -q '^fleet  *current' \
    || fail "fleet does not read as current in setup after the handover"

# Modules the catalog hides (another platform's, or operator-only without a
# confirmed account) still count: setup's own records keep it here.
setup_machine hidden-script
printf 'mac-boot\tx\tx\tx\n' >> "$HOME/.local/state/setup/script-state.tsv"
run_setup || { cat "$TMP/out"; fail "update with a hidden script module"; }
[[ -x "$HOME/.local/bin/setup" ]] || fail "setup removed though a hidden script module is installed"
setup_machine hidden-file
install -m 0755 "$ROOT/files/gpu-fancontrol" "$HOME/.local/bin/gpu-fancontrol"
printf '%s\tx\tx\n' "$HOME/.local/bin/gpu-fancontrol" >> "$HOME/.local/state/setup/installed.tsv"
run_setup || { cat "$TMP/out"; fail "update with a hidden file module"; }
[[ -x "$HOME/.local/bin/setup" ]] || fail "setup removed though a hidden file module is installed"
state_has fleet && fail "setup still manages fleet next to a hidden module"

# A timer that does not come on hands nothing over, and setup stays.
setup_machine no-timer
touch "$TMP/no-systemd"
run_setup && fail "update reported success without fleet's timer"
rm "$TMP/no-systemd"
state_has fleet && state_has auth || fail "a failed handover dropped setup's state"
[[ -x "$HOME/.local/bin/setup" && -x "$HOME/.local/bin/schedule" ]] || fail "a failed handover removed setup"
# The next run retries and finishes.
run_setup || { cat "$TMP/out"; fail "retry after a failed handover"; }
[[ ! -e "$HOME/.local/bin/setup" ]] || fail "retry did not finish the handover"

# A first `setup install fleet` whose hand-over fails after fleet is on disk
# stays pending: status reads outdated, setup stays, and the next update retries.
fresh_home first-install
mkdir -p "$HOME/.local/state/setup"
install -m 0755 "$ROOT/bin/setup" "$HOME/.local/bin/setup"
printf '%s\t%s\t%s\n' "$HOME/.local/bin/setup" "$(sha "$ROOT/bin/setup")" "$(sha "$ROOT/bin/setup")" \
    > "$HOME/.local/state/setup/installed.tsv"
touch "$TMP/no-systemd"
LINUX_SETUP_SOURCE_URL="file://$SRC" zsh "$HOME/.local/bin/setup" --batch install fleet >"$TMP/out" 2>&1 \
    && fail "install reported success without fleet's timer"
rm "$TMP/no-systemd"
[[ -x "$HOME/.local/bin/fleet" ]] || { cat "$TMP/out"; fail "the failed hand-over left no fleet to retry with"; }
state_has fleet || fail "a failed first hand-over left nothing pending"
[[ -x "$HOME/.local/bin/setup" ]] || fail "a failed first hand-over removed setup"
LINUX_SETUP_SOURCE_URL="file://$SRC" zsh "$HOME/.local/bin/setup" status fleet 2>/dev/null | grep -q '^fleet  *outdated' \
    || fail "a pending hand-over reads as current"
run_setup || { cat "$TMP/out"; fail "retry of a failed first hand-over"; }
state_has fleet && fail "a finished hand-over left fleet pending"
[[ ! -e "$HOME/.local/bin/setup" ]] || { cat "$TMP/out"; fail "retry did not finish the hand-over"; }

# An onboarding prompt from before: `curl .../install.sh | zsh -s -- install fleet`
# ends with standalone fleet and no setup.
fresh_home old-prompt
LINUX_SETUP_SOURCE_URL="file://$SRC" zsh "$ROOT/install.sh" install fleet </dev/null >"$TMP/out" 2>&1 \
    || { cat "$TMP/out"; fail "old onboarding prompt"; }
installed_payload || { cat "$TMP/out"; fail "old onboarding prompt did not install fleet"; }
[[ ! -e "$HOME/.local/bin/setup" && ! -e "$HOME/.local/state/setup" ]] || { cat "$TMP/out"; fail "old onboarding prompt left setup"; }

echo "fleet standalone tests passed"
