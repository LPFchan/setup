#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode"
printf '{"provider":{"foreign":{}},"disabled_providers":["foreign-disabled"]}\n' > "$HOME/.config/opencode/opencode.json"
printf '{"demo":{"type":"api","key":"demo-key"}}\n' > "$HOME/.local/share/opencode/auth.json"
printf '{"servers":{"demo":{"baseURL":"http://demo"},"unused":{"baseURL":"http://unused"}}}\n' > "$HOME/.config/opencode/refresh-models.json"

python3 - <<PY
import importlib.machinery, importlib.util, json, os, sys
path = '$ROOT/files/refresh-models'
loader = importlib.machinery.SourceFileLoader('refresh_models_test', path)
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)

cfg = m._migrate_provider_statuses(m.load_json(m.CONFIG_PATH))
assert cfg['servers']['demo']['enabled'] is True
assert cfg['servers']['unused']['enabled'] is False
m._sync_opencode_provider_statuses(cfg['servers'])
opencode = m.load_json(m.OPENCODE_PATH)
assert opencode['disabled_providers'] == ['foreign-disabled', 'unused']
assert 'foreign' in opencode['provider']

seen = []
m.refresh_server = lambda name, cfg: seen.append(name) or True
sys.argv = [path]
m.main()
assert seen == ['demo'], seen

assert m._set_provider_enabled('demo', False)
cfg = m.load_json(m.CONFIG_PATH)
assert cfg['servers']['demo']['enabled'] is False
assert set(m.load_json(m.OPENCODE_PATH)['disabled_providers']) == {
    'foreign-disabled', 'demo', 'unused'
}

assert not m._set_provider_enabled('unused', True)
assert m._set_provider_enabled('demo', True)
assert m.load_json(m.CONFIG_PATH)['servers']['demo']['enabled'] is True

sys.argv = [path, 'auth', 'unused', 'unused-key']
m.cmd_auth()
assert m.load_json(m.CONFIG_PATH)['servers']['unused']['enabled'] is True
assert m.load_json(m.OPENCODE_PATH)['disabled_providers'] == ['foreign-disabled']

sys.argv = [path, 'unused']
m.refresh_server = lambda name, cfg: seen.append(name) or True
m.main()
assert seen[-1] == 'unused'
PY

echo "refresh-models provider tests passed"
