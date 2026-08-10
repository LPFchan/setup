#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export PROVIDERS_REGISTRY="$TMP/registry.json"
export PROVIDER_STATE_PATH="$HOME/.config/providers/state.json"
export PROVIDERS_CACHE_PATH="$HOME/.config/providers/credentials.json"
mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode"
printf '{"provider":{"foreign":{}},"disabled_providers":["foreign-disabled"]}\n' > "$HOME/.config/opencode/opencode.json"
printf '{"demo":{"type":"api","key":"demo-key"}}\n' > "$HOME/.local/share/opencode/auth.json"
export HERMES_CONFIG="$HOME/.hermes/config.yaml"
mkdir -p "$HOME/.hermes"
cat > "$HERMES_CONFIG" <<'EOF'
custom_providers:
  - name: demo
    base_url: http://old-demo
    api_key: old-key
    model: old-model
    models:
      - stale-1
      - stale-2
  - name: foreign
    base_url: http://foreign
    api_key: foreign-key
    models:
      - foreign-model
  - name: unused
    base_url: http://old-unused
    api_key: unused-key
    models:
      - stale-3
EOF
cat > "$PROVIDERS_REGISTRY" <<'EOF'
{"version":1,"profiles":[
  {"name":"codex","provider_type":"OpenAIResponses","base_url":"https://codex.invalid","auth":{"type":"oauth","provider":"chatgpt"},"enabled":true,"models":{"haiku":"h","sonnet":"s","opus":"o"}},
  {"name":"demo","provider_type":"OpenAICompatible","base_url":"http://demo","auth":{"type":"api-key","store":"opencode","key":"demo"},"enabled":true,"models":{"haiku":"h","sonnet":"s","opus":"o"}},
  {"name":"unused","provider_type":"OpenAICompatible","base_url":"http://unused","auth":{"type":"api-key","store":"opencode","key":"unused"},"enabled":true,"models":{"haiku":"h","sonnet":"s","opus":"o"}}
]}
EOF
printf '{"servers":{"demo":{"baseURL":"http://old-demo","enabled":true},"unused":{"baseURL":"http://old-unused","enabled":false}}}\n' > "$HOME/.config/opencode/refresh-models.json"
printf '{"providers":{"demo":{"enabled":true},"unused":{"enabled":false}}}\n' > "$HOME/.config/opencode/refresh-models-state.json"

python3 - <<PY
import copy, importlib.machinery, importlib.util, json, os, sys
path = '$ROOT/files/providers'
loader = importlib.machinery.SourceFileLoader('providers_test', path)
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)

# Network-optional: no vault token means the local cache is authoritative.
m.vault_available = lambda: False

# Keep the test hermetic: the real ocx/codex sync must not run from here.
m._sync_opencodex_provider_statuses = lambda: None

fixture_registry = m.REGISTRY_PATH
m.REGISTRY_PATH = '$ROOT/files/provider-registry.json'
assert set(m._load_servers()) == {'grimoire', 'crofai', 'commandcode', 'deepseek', 'kimicode', 'meta'}
m.CLAUDEX_BIN = os.path.join('$TMP', 'claudex')
m.OPENCODEX_BIN = os.path.join('$TMP', 'opencodex')
for executable in (m.CLAUDEX_BIN, m.OPENCODEX_BIN):
    with open(executable, 'w') as handle:
        handle.write('#!/bin/sh\n')
    os.chmod(executable, 0o700)
assert m._provider_consumer_modules() == ['claudex', 'opencodex', 'providers']
m.REGISTRY_PATH = fixture_registry
servers = m._load_servers()
assert set(servers) == {'demo', 'unused'}
assert servers['demo']['baseURL'] == 'http://demo'
state = m._load_provider_state()
assert state == {'version': 1, 'providers': {'demo': {'enabled': True}, 'unused': {'enabled': False}}}
assert os.path.exists(m.STATE_PATH)
assert not os.path.exists(m.LEGACY_STATE_PATH)
assert not os.path.exists(m.LEGACY_CONFIG_PATH)

# Once neutral state exists, neither legacy input can overwrite it and both
# obsolete copies are removed after the neutral file validates.
m.save_json(m.LEGACY_STATE_PATH, {'providers': {'demo': {'enabled': False}}})
m.save_json(m.LEGACY_CONFIG_PATH, {'servers': {'demo': {'enabled': False}}})
assert m._load_provider_state() == state
assert m.load_json(m.STATE_PATH) == state
assert not os.path.exists(m.LEGACY_STATE_PATH)
assert not os.path.exists(m.LEGACY_CONFIG_PATH)

# The oldest combined config still migrates directly into the neutral schema.
os.remove(m.STATE_PATH)
m.save_json(m.LEGACY_CONFIG_PATH, {
    'servers': {
        'demo': {'baseURL': 'http://old-demo', 'enabled': True},
        'unused': {'baseURL': 'http://old-unused', 'enabled': False},
    },
})
assert m._load_provider_state() == state
assert not os.path.exists(m.LEGACY_CONFIG_PATH)

legacy = {'servers': {'private-only': {'baseURL': 'https://private.invalid/v1', 'enabled': False}}}
os.remove(m.STATE_PATH)
m.save_json(m.LEGACY_CONFIG_PATH, legacy)
assert m._load_provider_state() == {'version': 1, 'providers': {}}
assert not os.path.exists(m.LEGACY_CONFIG_PATH)
m.save_json_atomic(m.STATE_PATH, state)

# The profile array is claudex's alone: providers routes by provider and must
# accept a registry that no longer carries one.
profileless = copy.deepcopy(m.load_json('$ROOT/files/provider-registry.json'))
del profileless['profiles']
m._validate_registry(profileless)
m.save_json(m.REGISTRY_PATH + '.profileless', profileless)
profile_registry, m.REGISTRY_PATH = m.REGISTRY_PATH, m.REGISTRY_PATH + '.profileless'
assert set(m._load_servers()) == {'grimoire', 'crofai', 'commandcode', 'deepseek', 'kimicode', 'meta'}
m.REGISTRY_PATH = profile_registry

# The registry is fetched unverified, so validation is the only gate: a copy
# that routes nothing must be refused rather than silently unmanaging every
# provider. Both populated shapes stay valid.
for empty in ({'version': 1}, {'version': 1, 'providers': {}}, {'version': 1, 'profiles': []}):
    try:
        m._validate_registry(copy.deepcopy(empty))
    except ValueError:
        pass
    else:
        raise AssertionError(f'content-free registry passed validation: {empty}')
m._validate_registry(m.load_json('$ROOT/files/provider-registry.json'))
m._validate_registry(copy.deepcopy(profileless))
m._validate_registry(m.load_json(fixture_registry))

malformed_registry = copy.deepcopy(m.load_json('$ROOT/files/provider-registry.json'))
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

# Refresh: only enabled providers with a key are refreshed.
real_refresh_server = m.refresh_server  # restored for the mirror assertions
seen = []
m.refresh_server = lambda name, cfg: seen.append(name) or True
sys.argv = [path]
m.main()
assert seen == ['demo'], seen

# The Hermes mirror runs off the refreshed list, never the registry: fetch
# two live ids (one stale) and confirm the matching entry was rewritten
# atomically (same inode as the previous file), the key came from the local
# cache, unrelated entries were left untouched, and no provider was created
# or deleted.
m.refresh_server = real_refresh_server
import os as _os


def _load_yaml(path):
    """Parse a YAML file for assertions (mirrors are written by the
    module's own _sync_hermes_mirror, which requires PyYAML to be present;
    the test suite runs where PyYAML is available)."""
    import yaml
    with open(path) as handle:
        return yaml.safe_load(handle)


before_inode = _os.stat(m.HERMES_CONFIG).st_ino
m.cache_set('demo', 'demo-key')
m.fetch_models = lambda base, auth: {
    'data': [{'id': 'fresh-1'}, {'id': 'fresh-2'}, {'id': 'stale-1'}]
}
assert m.refresh_server('demo', servers['demo'])
assert m.load_json(m.OPENCODE_PATH)['provider']['demo']['models'] == {
    'fresh-1': {'limit': {'context': 32768, 'output': 16384},
                'cost': {'input': 0, 'output': 0, 'cache_read': 0}},
    'fresh-2': {'limit': {'context': 32768, 'output': 16384},
                'cost': {'input': 0, 'output': 0, 'cache_read': 0}},
    'stale-1': {'limit': {'context': 32768, 'output': 16384},
                'cost': {'input': 0, 'output': 0, 'cache_read': 0}},
}
mirrored = _load_yaml(m.HERMES_CONFIG)
assert [e['name'] for e in mirrored['custom_providers']] == ['demo', 'foreign', 'unused']
entry = mirrored['custom_providers'][0]
assert entry['models'] == ['fresh-1', 'fresh-2', 'stale-1'], entry
assert entry['base_url'] == 'http://demo', entry
assert entry['api_key'] == 'demo-key', entry
assert entry['model'] == 'old-model'  # unrelated fields preserved
assert mirrored['custom_providers'][1] == {
    'name': 'foreign',
    'base_url': 'http://foreign',
    'api_key': 'foreign-key',
    'models': ['foreign-model'],
}
assert mirrored['custom_providers'][2]['models'] == ['stale-3']
assert _os.stat(m.HERMES_CONFIG).st_ino != before_inode  # atomic replace

# Idempotent: an unchanged mirror rewrites nothing.
before_mtime = _os.stat(m.HERMES_CONFIG).st_mtime
m.refresh_server('demo', servers['demo'])
assert _os.stat(m.HERMES_CONFIG).st_mtime == before_mtime

# A refreshed list without models leaves the entry untouched.
m.cache_remove('demo')
m.fetch_models = lambda base, auth: {'data': [{'id': 'fresh-3'}]}
m.cache_set('demo', 'demo-key')
m._sync_hermes_mirror('demo', 'http://demo', {})
assert _load_yaml(m.HERMES_CONFIG)['custom_providers'][0]['models'] == [
    'fresh-1', 'fresh-2', 'stale-1'
]

# Missing PyYAML skips silently instead of crashing the refresh.
m.fetch_models = lambda base, auth: {'data': [{'id': 'fresh-3'}]}
m.cache_set('demo', 'demo-key')
import builtins
real_import = __import__
def fake_import(name, *args, **kwargs):
    if name == 'yaml':
        raise ImportError('no PyYAML')
    return real_import(name, *args, **kwargs)
builtins.__dict__['__import__'] = fake_import
assert m.refresh_server('demo', servers['demo'])  # mirror skipped, refresh ok
builtins.__dict__['__import__'] = real_import
# The file content is still the previous mirrored list (mirror skipped).
assert _load_yaml(m.HERMES_CONFIG)['custom_providers'][0]['models'] == [
    'fresh-1', 'fresh-2', 'stale-1'
]

# An unparseable Hermes config skips silently and is never overwritten.
with open(m.HERMES_CONFIG, 'w') as handle:
    handle.write('custom_providers: [broken\n')
m.fetch_models = lambda base, auth: {'data': [{'id': 'fresh-3'}]}
assert m.refresh_server('demo', servers['demo'])
assert open(m.HERMES_CONFIG).read() == 'custom_providers: [broken\n'
with open(m.HERMES_CONFIG, 'w') as handle:
    handle.write('custom_providers:\n  - name: demo\n    models:\n      - stale-1\n')

# A provider with no matching entry is never created.
m._sync_hermes_mirror('ghost', 'http://ghost', {'a': {}})
assert 'ghost' not in [e['name'] for e in _load_yaml(m.HERMES_CONFIG)['custom_providers']]

# Enablement without a key is refused (key comes from vault or cache).
assert not m._set_provider_enabled('demo', False) is False  # no-op sanity
assert m._set_provider_enabled('demo', False)
assert m.load_json(m.STATE_PATH)['providers']['demo']['enabled'] is False
assert set(m.load_json(m.OPENCODE_PATH)['disabled_providers']) == {
    'foreign-disabled', 'demo', 'unused'
}

assert not m._set_provider_enabled('unused', True)  # no key yet
m.cache_set('unused', 'unused-key')
assert m._set_provider_enabled('unused', True)
assert m.load_json(m.STATE_PATH)['providers']['unused']['enabled'] is True
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
m.REGISTRY_PATH = '$ROOT/files/provider-registry.json'
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

# An unreadable migration source is never deleted.
os.remove(m.STATE_PATH)
with open(m.LEGACY_STATE_PATH, 'w') as handle:
    handle.write('{truncated')
assert m._load_provider_state() is None
assert os.path.exists(m.LEGACY_STATE_PATH)

# Naming convention: only {PROVIDER}_API_KEY items are conforming.
assert m._conforming_item_name('DEEPSEEK_API_KEY')
assert m._conforming_item_name('OPENCODE_GO_API_KEY')
assert not m._conforming_item_name('VAST.AI API KEY')
assert not m._conforming_item_name('GITHUB_COPILOT_OAUTH_TOKEN')
assert not m._conforming_item_name('deepseek_api_key')
PY

echo "providers provider tests passed"
