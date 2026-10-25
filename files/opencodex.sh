#!/usr/bin/env zsh
# setup-module: opencodex
# setup-type: script
#
# Installs the four-reel provider/model/effort/harness picker at
# ~/.local/bin/opencodex. fleet installs ocx, writes its config and keeps the
# proxy running (`fleet install ocx`); the picker only launches through it.
#
# Machines this module once gave its own OpenCodex runtime
# (~/.local/libexec/opencodex) hand it over to fleet on install or update.

(( ${+functions[git_clone_if_missing]} )) || source "${${(%):-%x}:A:h}/../lib/script-helpers.sh"

MODULE="opencodex"
BIN="${OPENCODEX_LAUNCHER:-$HOME/.local/bin/opencodex}"
SOURCE_BASE="${LINUX_SETUP_SOURCE_URL:-${SOURCE_URL:-https://raw.githubusercontent.com/LPFchan/setup/main}}"
LAUNCHER_SOURCE="${OPENCODEX_LAUNCHER_SOURCE:-$SOURCE_BASE/files/opencodex}"
FLEET="${FLEET_BIN:-$HOME/.local/bin/fleet}"
# What the old module installed. fleet leaves ocx alone while this runtime exists.
LEGACY_ROOT="$HOME/.local/libexec/opencodex"
LEGACY_OCX="$HOME/.local/bin/ocx"
LEGACY_FILES=("$HOME/.config/opencodex/managed-profiles.json" "$HOME/.opencodex/setup-live-applied")

_fetch_file() {
    local source="$1" destination="$2"
    if [[ -f "$source" ]]; then
        cp "$source" "$destination"
    elif (( ${+functions[fetch_source_url]} )); then
        fetch_source_url "$source" -o "$destination"
    else
        curl -fsSL "$source" -o "$destination"
    fi
}

_stage_launcher() {
    _fetch_file "$LAUNCHER_SOURCE" "$1" || {
        echo "opencodex: could not fetch launcher from $LAUNCHER_SOURCE" >&2
        return 1
    }
}

# Exit 0 once the running proxy has no turn in flight, 1 if it stays busy past
# OPENCODEX_IDLE_WAIT (default 120s). A proxy that does not answer has nothing
# to cut, so it reads as idle, like fleet's own check.
_proxy_idle() {
    python3 - "${OPENCODEX_IDLE_WAIT:-120}" <<'PY'
import json, pathlib, sys, time, urllib.request
home = pathlib.Path.home() / ".opencodex"
deadline = time.monotonic() + float(sys.argv[1])
try:
    port = json.loads((home / "runtime-port.json").read_text())["port"]
    token = (home / "admin-api-token").read_text().strip()
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(0)
request = urllib.request.Request(f"http://127.0.0.1:{port}/api/system/memory",
                                 headers={"Authorization": f"Bearer {token}"})
while True:
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            turns = json.loads(response.read().decode("utf-8", "replace"), strict=False).get("activeTurnCount")
    except (OSError, ValueError, AttributeError):
        sys.exit(0)
    if not turns:
        sys.exit(0)
    if time.monotonic() >= deadline:
        sys.exit(1)
    time.sleep(0.5)
PY
}

# Exit 0 once the proxy answers /healthz, polling up to OPENCODEX_ACTIVATE_WAIT
# (default 120s): `ocx service` gives a cold start ~20s, so it can exit 1 for a
# proxy that is still coming up.
_proxy_live() {
    python3 - "${OPENCODEX_ACTIVATE_WAIT:-120}" <<'PY'
import json, pathlib, sys, time, urllib.request
deadline = time.monotonic() + float(sys.argv[1])
while True:
    try:
        port = json.loads((pathlib.Path.home() / ".opencodex/runtime-port.json").read_text())["port"]
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=5) as response:
            if json.load(response).get("status") in ("ok", "restart_required"):
                sys.exit(0)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        pass
    if time.monotonic() >= deadline:
        sys.exit(1)
    time.sleep(2)
PY
}

# Exit 1 only when ocx's service record launches an installed ocx outside the
# old runtime. A path is judged by where it resolves, not by its name: with an
# npm prefix of ~/.local the new ocx is ~/.local/bin/ocx too. A missing record
# or a recorded path that is gone proves no new install, so both count as old.
_service_on_legacy() {
    python3 - "$LEGACY_ROOT" <<'PY'
import json, os, pathlib, sys
root = os.path.realpath(sys.argv[1]) + "/"
try:
    state = json.loads((pathlib.Path.home() / ".opencodex/service-state.json").read_text())
except (OSError, ValueError):
    sys.exit(0)
paths = [p for p in (state.get(k) for k in ("launcherPath", "bunPath", "cliPath")) if isinstance(p, str)]
legacy = not paths or any(not os.path.exists(p) or os.path.realpath(p).startswith(root) for p in paths)
sys.exit(0 if legacy else 1)
PY
}

# An ocx outside the old runtime on PATH or in nvm's bins (where fleet's own
# PATH looks), or nothing.
_new_ocx() {
    local dir
    for dir in ${(s.:.)PATH} $HOME/.nvm/versions/node/*/bin(N); do
        [[ -x "$dir/ocx" && ${${:-$dir/ocx}:A} != ${LEGACY_ROOT:A}/* ]] || continue
        print -r -- "$dir/ocx"
        return 0
    done
    return 1
}

# Move a machine off the old runtime onto fleet's ocx. Returns 0 when there is
# nothing (left) to hand over, 1 when the new install failed and the old
# runtime keeps serving, 2 when a busy proxy puts it off to the next run.
#
# `fleet install ocx` ends in `ocx service`, which restarts the proxy, so the
# idle wait comes first. The ~/.local/bin/ocx link goes before it: fleet would
# read it as ocx already installed, and ocx's service would keep launching the
# path it recorded. The old runtime stays on disk until the new proxy answers,
# since the old one draining its last turns still loads code from it.
_handover() {
    [[ -d "$LEGACY_ROOT" ]] || return 0
    if ! _proxy_idle; then
        echo "opencodex: the ocx proxy stayed busy; its hand-over to fleet is put off to the next run" >&2
        return 2
    fi
    local link ocx
    link=$(readlink "$LEGACY_OCX" 2>/dev/null) || link=""
    rm -f "$LEGACY_OCX"
    # `ocx service` exits 1 for a cold start still coming up, and fleet waits only
    # for a proxy it owns, so what came up decides rather than the exit code.
    "$FLEET" install ocx || echo "opencodex: fleet install ocx exited $?; waiting for the proxy" >&2
    # A retry finds the package an earlier attempt installed: fleet calls it
    # already installed and leaves a service it does not own yet unrepaired.
    if _service_on_legacy && ocx=$(_new_ocx); then
        "$ocx" service || echo "opencodex: ocx service exited $?; waiting for the proxy" >&2
    fi
    if ! _proxy_live || _service_on_legacy; then
        [[ -z "$link" || -e "$LEGACY_OCX" ]] || ln -s "$link" "$LEGACY_OCX"
        echo "opencodex: fleet install ocx did not take over; the old OpenCodex runtime keeps serving" >&2
        return 1
    fi
    rm -rf "$LEGACY_ROOT"
    rm -f "${LEGACY_FILES[@]}"
    # fleet left the config and Claude's route alone while the old runtime existed.
    # Pull only, like fleet's own module: an unattended run must not push local ~/.agents edits.
    "$FLEET" sync --pull || echo "opencodex: fleet sync --pull failed; fleet's next pass writes the ocx config and Claude's route" >&2
    echo "opencodex: handed the ocx proxy over to fleet"
}

_desired_hash_from() {
    setup_sha256_string < "$1"
}

_apply() {
    local action="$1" staged hash rc=0
    staged=$(mktemp)
    _stage_launcher "$staged" || { rm -f "$staged"; return 1; }
    _handover || rc=$?
    # Until it is handed over, the old launcher keeps serving fleet's calls into it.
    if (( rc != 0 )); then
        rm -f "$staged"
        return $(( rc == 2 ? 0 : 1 ))
    fi
    mkdir -p "${BIN:h}"
    cp "$staged" "$BIN.tmp.$$" && chmod +x "$BIN.tmp.$$" && mv "$BIN.tmp.$$" "$BIN" \
        || { rm -f "$staged" "$BIN.tmp.$$"; return 1; }
    hash=$(_desired_hash_from "$staged")
    rm -f "$staged"
    record_script_state "$MODULE" "launcher" "$hash" "$hash"
    echo "opencodex: $action -> $BIN"
}

install() {
    _apply installed
}

update() {
    _apply updated
}

status() {
    if ! is_script_installed "$MODULE"; then
        printf '%-25s %-12s\n' "$MODULE" "uninstalled"
        return 2
    fi
    local staged desired state=current local_label
    staged=$(mktemp)
    _stage_launcher "$staged" || { rm -f "$staged"; return 1; }
    desired=$(_desired_hash_from "$staged")
    local_label=${desired:0:7}
    if [[ -d "$LEGACY_ROOT" ]]; then
        state=outdated local_label=legacy-runtime
    elif ! cmp -s "$staged" "$BIN"; then
        state=outdated local_label=$([[ -f "$BIN" ]] && echo modified || echo missing)
    fi
    rm -f "$staged"
    printf '%-25s %-12s local=%s remote=%s target=%s\n' \
        "$MODULE" "$state" "$local_label" "${desired:0:7}" "$BIN"
    [[ "$state" == current ]]
}

uninstall() {
    # The proxy itself is fleet's; an old runtime is handed over, not left orphaned.
    _handover || return 1
    rm -f "$BIN"
    remove_script_state "$MODULE"
    echo "opencodex: uninstalled the launcher; fleet keeps ocx"
}
