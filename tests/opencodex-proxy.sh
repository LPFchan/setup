#!/usr/bin/env bash
set -euo pipefail

# `opencodex proxy` took over `harnesses proxy`: it repairs the service through
# `ocx service`, writes the ANTHROPIC_BASE_URL export only while the service is
# active, and removes it when the service stays down.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export OPENCODEX_BIN="$TMP/bin/ocx"
# A fixed port keeps the suite from probing a proxy running on this machine.
export HARNESSES_PROXY_PORT=10101
mkdir -p "$HOME/.claude" "$TMP/bin"

cat > "$OPENCODEX_BIN" <<'SH'
#!/bin/sh
echo "$*" >> "$HOME/ocx.log"
[ -e "$HOME/ocx-fails" ] && exit 1
exit 0
SH
cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/sh
echo "$*" >> "$HOME/systemctl.log"
if [ "$2" = is-active ]; then
    if [ -e "$HOME/proxy-down" ]; then echo inactive; exit 3; fi
    echo active
fi
exit 0
SH
chmod +x "$OPENCODEX_BIN" "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }

printf 'export KEEP=1\n' > "$HOME/.zshenv"
printf '{"model": "opus", "env": {"OTHER": "1"}}\n' > "$HOME/.claude/settings.json"
mkdir -p "$HOME/.config/environment.d"
touch "$HOME/.config/environment.d/10-harnesses-anthropic.conf"

python3 "$ROOT/files/opencodex" proxy >/dev/null || fail "proxy failed with an active service"
grep -q '^service$' "$HOME/ocx.log" || fail "ocx service was not run"
grep -q '^export KEEP=1$' "$HOME/.zshenv" || fail "unrelated .zshenv lines were lost"
grep -q '^export ANTHROPIC_BASE_URL=http://127.0.0.1:10101$' "$HOME/.zshenv" \
    || fail "the .zshenv export was not written"
[[ $(grep -c 'BEGIN harnesses:anthropic-base-url' "$HOME/.zshenv") == 1 ]] \
    || fail "the export block is missing or duplicated"
python3 - "$HOME/.claude/settings.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["model"] == "opus", data
assert data["env"] == {"OTHER": "1", "ANTHROPIC_BASE_URL": "http://127.0.0.1:10101"}, data
PY
[[ ! -e "$HOME/.config/environment.d/10-harnesses-anthropic.conf" ]] \
    || fail "the legacy environment.d export was left behind"
grep -q 'unset-environment ANTHROPIC_BASE_URL' "$HOME/systemctl.log" \
    || fail "the legacy systemd user export was not unset"

# A second run rewrites the block in place.
export HARNESSES_PROXY_PORT=10100
python3 "$ROOT/files/opencodex" proxy >/dev/null || fail "second proxy run failed"
[[ $(grep -c 'BEGIN harnesses:anthropic-base-url' "$HOME/.zshenv") == 1 ]] \
    || fail "a second run duplicated the export block"
grep -q '^export ANTHROPIC_BASE_URL=http://127.0.0.1:10100$' "$HOME/.zshenv" \
    || fail "a second run did not update the port"

# A service that stays down after repair loses the route, and only the route.
touch "$HOME/proxy-down"
if python3 "$ROOT/files/opencodex" proxy >/dev/null 2>&1; then
    fail "proxy succeeded with an inactive service"
fi
! grep -q 'ANTHROPIC_BASE_URL' "$HOME/.zshenv" || fail "the export survived an inactive service"
grep -q '^export KEEP=1$' "$HOME/.zshenv" || fail "removal took unrelated .zshenv lines"
python3 - "$HOME/.claude/settings.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["env"] == {"OTHER": "1"}, data
PY

# A failed repair leaves the export alone: the service may still be running.
rm "$HOME/proxy-down"
python3 "$ROOT/files/opencodex" proxy >/dev/null || fail "proxy failed to restore the export"
touch "$HOME/ocx-fails"
if python3 "$ROOT/files/opencodex" proxy >/dev/null 2>&1; then
    fail "proxy succeeded when ocx service failed"
fi
grep -q 'ANTHROPIC_BASE_URL' "$HOME/.zshenv" || fail "a failed repair removed the export"

# Settings that do not parse stop the run instead of being overwritten.
rm "$HOME/ocx-fails"
printf '{broken' > "$HOME/.claude/settings.json"
if python3 "$ROOT/files/opencodex" proxy >/dev/null 2>&1; then
    fail "proxy overwrote unparseable settings"
fi
[[ $(<"$HOME/.claude/settings.json") == '{broken' ]] || fail "unparseable settings were rewritten"

echo "opencodex proxy tests passed"
