#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export CLAUDEX_REGISTRY="$TMP/registry.json"
mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode"
printf '{"provider":{"foreign":{}},"disabled_providers":["foreign-disabled"]}\n' > "$HOME/.config/opencode/opencode.json"
printf '{"demo":{"type":"api","key":"demo-key"}}\n' > "$HOME/.local/share/opencode/auth.json"
cat > "$CLAUDEX_REGISTRY" <<'EOF'
{"version":1,"profiles":[
  {"name":"codex","provider_type":"OpenAIResponses","base_url":"https://codex.invalid","auth":{"type":"oauth","provider":"chatgpt"},"enabled":true,"models":{"haiku":"h","sonnet":"s","opus":"o"}},
  {"name":"demo","provider_type":"OpenAICompatible","base_url":"http://demo","auth":{"type":"api-key","store":"opencode","key":"demo"},"enabled":true,"models":{"haiku":"h","sonnet":"s","opus":"o"}},
  {"name":"unused","provider_type":"OpenAICompatible","base_url":"http://unused","auth":{"type":"api-key","store":"opencode","key":"unused"},"enabled":true,"models":{"haiku":"h","sonnet":"s","opus":"o"}}
]}
EOF
printf '{"servers":{"demo":{"baseURL":"http://old-demo","enabled":true},"unused":{"baseURL":"http://old-unused","enabled":false}}}\n' > "$HOME/.config/opencode/refresh-models.json"

python3 - <<PY
import copy, importlib.machinery, importlib.util, json, os, sys
path = '$ROOT/files/refresh-models'
loader = importlib.machinery.SourceFileLoader('refresh_models_test', path)
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)

fixture_registry = m.REGISTRY_PATH
m.REGISTRY_PATH = '$ROOT/files/claudex-profiles.json'
assert set(m._load_servers()) == {'grimoire', 'crofai', 'commandcode'}
m.REGISTRY_PATH = fixture_registry
servers = m._load_servers()
assert set(servers) == {'demo', 'unused'}
assert servers['demo']['baseURL'] == 'http://demo'
state = m._load_provider_state()
assert state == {'providers': {'demo': {'enabled': True}, 'unused': {'enabled': False}}}
assert os.path.exists(m.STATE_PATH)
assert not os.path.exists(m.LEGACY_CONFIG_PATH)

legacy = {'servers': {'private-only': {'baseURL': 'https://private.invalid/v1', 'enabled': False}}}
os.remove(m.STATE_PATH)
m.save_json(m.LEGACY_CONFIG_PATH, legacy)
assert m._load_provider_state() == {'providers': {}}
assert not os.path.exists(m.LEGACY_CONFIG_PATH)
m.save_json_atomic(m.STATE_PATH, state)

malformed_registry = copy.deepcopy(m.load_json('$ROOT/files/claudex-profiles.json'))
del malformed_registry['providers']['grimoire']['auth']['key']
try:
    m._validate_registry(malformed_registry)
except ValueError:
    pass
else:
    raise AssertionError('malformed provider descriptor passed validation')

m._sync_opencode_provider_statuses(servers)
opencode = m.load_json(m.OPENCODE_PATH)
assert opencode['disabled_providers'] == ['foreign-disabled', 'unused']
assert 'foreign' in opencode['provider']

seen = []
m.refresh_server = lambda name, cfg: seen.append(name) or True
sys.argv = [path]
m.main()
assert seen == ['demo'], seen

assert m._set_provider_enabled('demo', False)
assert m.load_json(m.STATE_PATH)['providers']['demo']['enabled'] is False
assert set(m.load_json(m.OPENCODE_PATH)['disabled_providers']) == {
    'foreign-disabled', 'demo', 'unused'
}

assert not m._set_provider_enabled('unused', True)
assert m._set_provider_enabled('demo', True)
assert m.load_json(m.STATE_PATH)['providers']['demo']['enabled'] is True

sys.argv = [path, 'auth', 'unused', 'unused-key']
m.cmd_auth()
assert m.load_json(m.STATE_PATH)['providers']['unused']['enabled'] is True
assert m.load_json(m.OPENCODE_PATH)['disabled_providers'] == ['foreign-disabled']

sys.argv = [path, 'unused']
m.refresh_server = lambda name, cfg: seen.append(name) or True
m.main()
assert seen[-1] == 'unused'

import builtins
builtins.input = lambda prompt='': 'grimoire'
m.REGISTRY_PATH = '$ROOT/files/claudex-profiles.json'
try:
    m._add_provider()
except ValueError as exc:
    assert 'unique' in str(exc)
else:
    raise AssertionError('provider add allowed a collision with a registry provider')

m.REGISTRY_PATH = fixture_registry
answers = iter(['added', 'https://added.invalid/v1', 'y'])
builtins.input = lambda prompt='': next(answers)
m.getpass.getpass = lambda prompt='': 'secret-token'
m.fetch_models = lambda base, auth: {'data': [{'id': 'small'}, {'id': 'large'}]}
selections = iter(['large', 'large', 'small'])
m._choose = lambda prompt, options: next(selections)
captured = {}
m._provision_provider = lambda profile, token: captured.update(profile=profile, token=token)
m._add_provider()
assert captured['profile']['name'] == 'added'
assert captured['profile']['models'] == {'haiku': 'small', 'sonnet': 'large', 'opus': 'large'}
assert captured['token'] == 'secret-token'

with open(m.STATE_PATH, 'w') as handle:
    handle.write('{truncated')
assert not m._provider_enabled('demo', servers['demo'])
PY

echo "refresh-models provider tests passed"
