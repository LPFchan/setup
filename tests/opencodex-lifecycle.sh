#!/usr/bin/env zsh
set -euo pipefail

ROOT=${0:A:h:h}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_STATE_HOME="$TEST_TMP/state"
export OPENCODEX_LAUNCHER="$HOME/.local/bin/opencodex"
export OPENCODEX_ROOT="$HOME/.local/libexec/opencodex"
export OPENCODEX_BIN="$HOME/.local/bin/ocx"
export OPENCODEX_CONFIG="$HOME/.opencodex/config.json"
export OPENCODEX_MANAGED="$HOME/.opencodex/setup-managed-providers.json"
export OPENCODEX_REGISTRY="$HOME/.config/opencodex/managed-profiles.json"
export OPENCODEX_AUTH_JSON="$HOME/.local/share/opencode/auth.json"
export OPENCODEX_LAUNCHER_SOURCE="$ROOT/files/opencodex"
export OPENCODEX_REGISTRY_SOURCE="$ROOT/files/provider-registry.json"
export OPENCODEX_RELEASE_VERSION="2.7.42"
export OPENCODEX_STOP_TIMEOUT_DROPIN="$HOME/.config/systemd/user/opencodex-proxy.service.d/50-stop-timeout.conf"
mkdir -p "${OPENCODEX_LAUNCHER:h}" "${OPENCODEX_REGISTRY:h}" "$XDG_STATE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/lib/script-helpers.sh"
source "$ROOT/files/opencodex.sh"

# The live-version probe opens a real socket on the configured port, so left
# alone the suite would answer from whatever proxy happens to be running on the
# machine running the tests. Unknown is the tolerated case; the drift cases
# below stub it deliberately.
_live_proxy_version() { print '' }
# Keep the drop-in writes below from reloading this machine's user manager.
systemctl() { :; }

OPENCODEX_RELEASE_VERSION=""
npm() { print '9.8.7'; }
[[ "$(_resolve_release_version)" == "9.8.7" ]] || fail "npm latest version was not resolved"
npm() { print 'undefined'; }
if _resolve_release_version >/dev/null 2>&1; then
    fail "empty npm latest metadata was accepted"
fi
unfunction npm
OPENCODEX_RELEASE_VERSION="2.7.42"

npm_args=""
npm() {
    npm_args="$*"
    local prefix=""
    while (( $# )); do
        if [[ "$1" == --prefix ]]; then prefix="$2"; shift 2; else shift; fi
    done
    mkdir -p "$prefix/node_modules/.bin"
    print '#!/bin/sh\necho opencodex 9.8.7' > "$prefix/node_modules/.bin/ocx"
    chmod +x "$prefix/node_modules/.bin/ocx"
}
_ensure_runtime "9.8.7"
[[ "$npm_args" == *"@bitkyc08/opencodex@9.8.7"* ]] || fail "resolved OpenCodex package was not installed"
[[ "$npm_args" != *"--allow-scripts"* ]] || fail "project install used the rejected allow-scripts CLI flag"
grep -q '"bun": true' "$OPENCODEX_ROOT/package.json" \
    || fail "OpenCodex runtime package did not approve Bun's install script"
[[ "$(_installed_version)" == "9.8.7" ]] || fail "resolved OpenCodex runtime version is wrong"
# The runtime is now installed verbatim: the Zen session patch went with
# opencode-zen's retirement, so nothing rewrites upstream's source in place and
# an upstream release can no longer break the install by moving those lines.
[[ ! -e "$OPENCODEX_ROOT/.setup-opencodex-zen-session.patch.sha256" ]] \
    || fail "a retired runtime patch left its integrity marker behind"
unfunction npm
rm -f "$OPENCODEX_BIN"
rm -rf "$OPENCODEX_ROOT"

install_surfaces() {
    cp "$ROOT/files/opencodex" "$BIN"
    chmod +x "$BIN"
    cp "$ROOT/files/provider-registry.json" "$REGISTRY"
    cat > "$OPENCODEX_BIN" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then echo 'opencodex 2.7.42'; fi
if [ "${1:-}" = service ] && [ "${2:-}" = status ] && [ -e "$HOME/.opencodex/service-stopped" ]; then exit 1; fi
EOF
    chmod +x "$OPENCODEX_BIN"
    _apply_all_providers
    _write_stop_timeout >/dev/null
}

expect_status() {
    local expected_rc="$1" expected_word="$2" output rc=0
    output=$(status) || rc=$?
    [[ "$rc" == "$expected_rc" ]] || fail "status returned $rc, expected $expected_rc: $output"
    [[ "$output" == *"$expected_word"* ]] || fail "status omitted $expected_word: $output"
}

install_surfaces
hash=$(_desired_hash)
staged=$(mktemp -d)
_stage_assets "$staged"
[[ "$(_desired_hash_from "$staged" "2.7.42")" != "$(_desired_hash_from "$staged" "2.7.43")" ]] \
    || fail "resolved OpenCodex version does not participate in desired state"
rm -rf "$staged"
record_script_state "$MODULE" "profile" "$hash" "$hash"
expect_status 0 current
IFS=$'\t' read -r ref_type _ < <(script_state_for "$MODULE")
[[ "$ref_type" == "release:2.7.42" ]] || fail "readable OpenCodex release was not recorded"

OPENCODEX_RELEASE_VERSION="2.7.43"
expect_status 1 outdated
OPENCODEX_RELEASE_VERSION="2.7.42"
expect_status 0 current

OPENCODEX_RELEASE_VERSION=""
npm() { return 1; }
expect_status 0 unknown
unfunction npm
OPENCODEX_RELEASE_VERSION="2.7.42"

touch "$HOME/.opencodex/service-stopped"
expect_status 1 outdated
rm "$HOME/.opencodex/service-stopped"
expect_status 0 current

# A registered service says nothing about which build is serving: an upgrade
# swaps the package tree under a running proxy and the old one keeps answering.
# Recording that as "current" is what leaves setup with nothing left to retry.
_live_proxy_version() { print '2.7.42' }
expect_status 0 current
_live_proxy_version() { print '2.7.41' }
expect_status 1 outdated
_live_proxy_version() { print '' }
expect_status 0 current

# ...and the activation step restarts a proxy the install left behind.
restart_calls=0
cat > "$OPENCODEX_BIN" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then echo 'opencodex 2.7.42'; fi
if [ "${1:-}" = service ] && [ "${2:-}" = restart ]; then echo restarted >> "$HOME/.opencodex/restarts"; fi
EOF
chmod +x "$OPENCODEX_BIN"
rm -f "$HOME/.opencodex/restarts"
_live_proxy_version() { [[ -e "$HOME/.opencodex/restarts" ]] && print '2.7.42' || print '2.7.41' }
_activate_runtime || fail "activation did not recover a proxy left on the previous build"
[[ -f "$HOME/.opencodex/restarts" ]] || fail "activation never restarted the stale proxy"

_live_proxy_version() { print '2.7.41' }
rm -f "$HOME/.opencodex/restarts"
if _activate_runtime 2>/dev/null; then
    fail "activation reported success while the previous build kept serving"
fi
# Activation goes through bare `ocx service` (install when absent, else repair).
# `service install` over a loaded service unloads it, then a proxy still shutting
# down refuses to stop, and the install aborts with nothing serving.
cat > "$OPENCODEX_BIN" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then echo 'opencodex 2.7.42'; fi
if [ "${1:-}" = service ]; then echo "service ${2:-}" >> "$HOME/.opencodex/service-calls"; fi
EOF
chmod +x "$OPENCODEX_BIN"
rm -f "$HOME/.opencodex/service-calls"
_live_proxy_version() { print '2.7.42' }
_activate_runtime || fail "activation failed with the installed build serving"
[[ "$(cat "$HOME/.opencodex/service-calls")" == "service " ]] \
    || fail "activation did not use bare ocx service: $(cat "$HOME/.opencodex/service-calls")"
_live_proxy_version() { print '' }
install_surfaces
expect_status 0 current

print '# drift' >> "$BIN"
expect_status 1 outdated
install_surfaces

# systemd's default 90s stop timeout would SIGKILL the proxy mid-drain.
if [[ "$(uname -s)" == Linux ]]; then
    [[ "$(<"$OPENCODEX_STOP_TIMEOUT_DROPIN")" == *"TimeoutStopSec=330"* ]] \
        || fail "the proxy stop-timeout drop-in was not written"
    rm "$OPENCODEX_STOP_TIMEOUT_DROPIN"
    expect_status 1 outdated
    install_surfaces
    expect_status 0 current
fi

rm -f "$OPENCODEX_BIN"
expect_status 1 outdated
install_surfaces

providers_registry="$HOME/.config/providers/registry.json"
mkdir -p "${providers_registry:h}"
cp "$ROOT/files/provider-registry.json" "$providers_registry"
(
    export PROVIDERS_REGISTRY="$providers_registry"
    source "$ROOT/files/providers.sh"
    uninstall >/dev/null
)
[[ -f "$REGISTRY" ]] || fail "providers uninstall removed opencodex's independent snapshot"
[[ ! -e "$providers_registry" ]] || fail "providers uninstall left its own snapshot"

# Uninstalling takes down the route to the proxy it stops.
mkdir -p "$HOME/.claude"
printf 'export KEEP=1\n# BEGIN harnesses:anthropic-base-url\nexport ANTHROPIC_BASE_URL=http://127.0.0.1:1\n# END harnesses:anthropic-base-url\n' >> "$HOME/.zshenv"
printf '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:1"}}\n' > "$HOME/.claude/settings.json"
# While the route cannot come off, nothing is torn down.
printf '{' > "$HOME/.claude/settings.json"
uninstall 2>/dev/null && fail "opencodex uninstall passed a route it could not remove"
[[ -e "$BIN" && -e "$REGISTRY" ]] || fail "a failed route removal still tore down opencodex"
# A gateway the user set in place of the proxy is not opencodex's to remove.
printf '{"env": {"ANTHROPIC_BASE_URL": "https://gw.example"}}\n' > "$HOME/.claude/settings.json"
python3 "$BIN" __unexport >/dev/null || fail "unexport with a user gateway"
grep -q 'gw.example' "$HOME/.claude/settings.json" || fail "unexport removed the user's own base URL"
# A block missing its end line cannot come off, so unexport fails rather
# than leave new shells routed to a stopped proxy.
cp "$HOME/.zshenv" "$TEST_TMP/zshenv.keep"
printf '# BEGIN harnesses:anthropic-base-url\nexport ANTHROPIC_BASE_URL=http://127.0.0.1:1\n' >> "$HOME/.zshenv"
python3 "$BIN" __unexport >/dev/null 2>&1 && fail "unexport passed a route block without its end"
grep -q 'ANTHROPIC_BASE_URL=http://127.0.0.1:1' "$HOME/.zshenv" || fail "unexport cut into a block without its end"
mv "$TEST_TMP/zshenv.keep" "$HOME/.zshenv"
printf '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:1"}}\n' > "$HOME/.claude/settings.json"
# A deleted launcher is fetched again for the route; while it cannot be,
# nothing is torn down.
rm "$BIN"
LAUNCHER_SOURCE="$TEST_TMP/missing" uninstall 2>/dev/null && fail "opencodex uninstall passed a route it had no launcher for"
[[ -e "$REGISTRY" ]] || fail "a missing launcher still tore down opencodex"
# Even fetched without its executable bit.
cp "$ROOT/files/opencodex" "$TEST_TMP/launcher"; chmod -x "$TEST_TMP/launcher"
LAUNCHER_SOURCE="$TEST_TMP/launcher" uninstall
! grep -q ANTHROPIC_BASE_URL "$HOME/.zshenv" "$HOME/.claude/settings.json" \
    || fail "opencodex uninstall left the route to its stopped proxy"
grep -q '^export KEEP=1$' "$HOME/.zshenv" || fail "opencodex uninstall dropped unrelated exports"
[[ ! -e "$REGISTRY" ]] || fail "opencodex uninstall left its provider snapshot"
[[ ! -e "$BIN" && ! -e "$OPENCODEX_ROOT" ]] || fail "opencodex uninstall left runtime files"
[[ ! -e "${OPENCODEX_STOP_TIMEOUT_DROPIN:h}" ]] || fail "opencodex uninstall left the stop-timeout drop-in"

echo "opencodex lifecycle tests passed"
