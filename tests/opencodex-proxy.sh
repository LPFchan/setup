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

# fleet's nightly __export writes the route only while the service is up and
# never removes it.
touch "$HOME/proxy-down"
python3 "$ROOT/files/opencodex" __export >/dev/null || fail "__export failed with the service down"
! grep -q 'ANTHROPIC_BASE_URL' "$HOME/.zshenv" || fail "__export wrote a route to a stopped proxy"
rm "$HOME/proxy-down"
python3 "$ROOT/files/opencodex" __export >/dev/null || fail "__export failed"
grep -q '^export ANTHROPIC_BASE_URL=http://127.0.0.1:10100$' "$HOME/.zshenv" \
    || fail "__export did not write the route"
touch "$HOME/proxy-down"
python3 "$ROOT/files/opencodex" __export >/dev/null
grep -q 'ANTHROPIC_BASE_URL' "$HOME/.zshenv" || fail "__export removed the route"
[[ $(python3 "$ROOT/files/opencodex" __proxy-url) == http://127.0.0.1:10100 ]] \
    || fail "__proxy-url did not print the proxy address"

# A failed repair leaves the export alone: the service may still be running.
rm "$HOME/proxy-down"
# OPENCODEX_BIN names the install to repair, even with another ocx on PATH.
mkdir -p "$TMP/other"
printf '#!/bin/sh\ntouch "$HOME/wrong-ocx"\n' > "$TMP/other/ocx"
chmod +x "$TMP/other/ocx"
PATH="$TMP/other:$PATH" python3 "$ROOT/files/opencodex" proxy >/dev/null || fail "proxy failed to restore the export"
[[ ! -e "$HOME/wrong-ocx" ]] || fail "proxy ran the ocx on PATH instead of OPENCODEX_BIN"
touch "$HOME/ocx-fails"
if OPENCODEX_ACTIVATE_WAIT=0 python3 "$ROOT/files/opencodex" proxy >/dev/null 2>&1; then
    fail "proxy succeeded when ocx service failed"
fi
grep -q 'ANTHROPIC_BASE_URL' "$HOME/.zshenv" || fail "a failed repair removed the export"

# A fake proxy on a free port answers /healthz and /v1/models, published
# through a runtime-port file at a non-default OPENCODEX_RUNTIME_PORT path.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cat > "$TMP/fake-proxy.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"status": "ok", "version": "1"} if self.path == "/healthz" else {"data": []}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
export OPENCODEX_RUNTIME_PORT="$TMP/runtime-port.json"
printf '{"port": %s}\n' "$PORT" > "$OPENCODEX_RUNTIME_PORT"
unset HARNESSES_PROXY_PORT

# A cold start that outlives ocx's own wait is not a failure: the proxy comes
# up a few seconds later and the export follows it, on the configured port.
(sleep 3; exec python3 "$TMP/fake-proxy.py" "$PORT") &
PROXY_PID=$!
trap 'kill $PROXY_PID 2>/dev/null; rm -rf "$TMP"' EXIT
OPENCODEX_ACTIVATE_WAIT=30 python3 "$ROOT/files/opencodex" proxy >/dev/null 2>&1 \
    || fail "proxy gave up on a slow cold start"
grep -q "^export ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT$" "$HOME/.zshenv" \
    || fail "the export ignored OPENCODEX_RUNTIME_PORT"
kill $PROXY_PID; wait $PROXY_PID 2>/dev/null || true
trap 'rm -rf "$TMP"' EXIT
export HARNESSES_PROXY_PORT=10101

# Settings that do not parse stop the run instead of being overwritten.
rm "$HOME/ocx-fails"
printf '{broken' > "$HOME/.claude/settings.json"
if python3 "$ROOT/files/opencodex" proxy >/dev/null 2>&1; then
    fail "proxy overwrote unparseable settings"
fi
[[ $(<"$HOME/.claude/settings.json") == '{broken' ]] || fail "unparseable settings were rewritten"

echo "opencodex proxy tests passed"
