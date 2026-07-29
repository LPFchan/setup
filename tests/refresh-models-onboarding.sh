#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/custom-state"
mkdir -p "$HOME/.config/opencode" "$HOME/.local/bin"
export CLAUDEX_REGISTRY="$TMP/registry.json"
cat > "$CLAUDEX_REGISTRY" <<'EOF'
{"version":1,"profiles":[
  {"name":"demo","provider_type":"OpenAICompatible","base_url":"http://demo","auth":{"type":"api-key","store":"opencode","key":"demo"},"enabled":true,"models":{"haiku":"h","sonnet":"s","opus":"o"}}
]}
EOF

python3 - <<PY
import importlib.machinery, importlib.util, os, sys
path = '$ROOT/files/refresh-models'
for provider in ('demo', 'grimoire', 'crofai', 'commandcode'):
    os.environ.pop(f'{provider.upper()}_API_KEY', None)
loader = importlib.machinery.SourceFileLoader('refresh_models_onboarding_test', path)
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
m._is_macos = lambda: False
m.subprocess.run = lambda *a, **k: type('R', (), {'returncode': 0, 'stderr': b''})()
sys.argv = [path, 'enable']
m.cmd_enable()
service_path = os.path.join(m.SERVICE_DIR, 'refresh-models.service')
with open(service_path) as f:
    service_unit = f.read()
assert f'ExecStart={os.path.abspath(path)}\n' in service_unit
assert 'EnvironmentFile' not in service_unit
assert '.zshenv' not in service_unit
assert m._load_servers()['demo']['baseURL'] == 'http://demo'
assert m._load_provider_state() == {'providers': {}}
PY

marker="$XDG_STATE_HOME/setup/refresh-models.needs-provider-setup"
[[ -f "$marker" ]] || { echo "provider onboarding marker was not created" >&2; exit 1; }

cat > "$HOME/.local/bin/refresh-models" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$AUTH_LOG"
exit "${AUTH_RC:-0}"
EOF
chmod +x "$HOME/.local/bin/refresh-models"
cat > "$TMP/driver" <<EOF
#!/usr/bin/env zsh
export HOME='$HOME' XDG_STATE_HOME='$XDG_STATE_HOME' STATE_DIR='$XDG_STATE_HOME/setup'
export SETUP_SOURCE_ONLY=1 PATH='/usr/bin:/bin'
source '$ROOT/bin/setup'
_post_refresh_models_setup
EOF
chmod +x "$TMP/driver"

run_driver() {
    if [[ "$(uname -s)" == Darwin ]]; then
        script -q /dev/null "$TMP/driver"
    else
        script -qec "$TMP/driver" /dev/null
    fi
}

AUTH_LOG="$TMP/auth.log" AUTH_RC=7 run_driver >/dev/null 2>&1 || true
[[ -e "$marker" ]] || { echo "failed provider setup removed retry marker" >&2; exit 1; }
[[ $(cat "$TMP/auth.log") == auth ]] || { echo "provider setup did not call refresh-models auth" >&2; exit 1; }

AUTH_LOG="$TMP/auth.log" AUTH_RC=0 run_driver >/dev/null 2>&1
[[ ! -e "$marker" ]] || { echo "successful provider setup kept retry marker" >&2; exit 1; }

echo "refresh-models onboarding tests passed"
