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
  - name: ghost
    base_url: http://ghost
    api_key: ghost-key
    models:
      - ghost-model
EOF
cat > "$PROVIDERS_REGISTRY" <<'EOF'
{"version":1,"providers":{
  "demo":{"provider_type":"OpenAICompatible","base_url":"http://demo","api_format":"openai","npm":"@ai-sdk/openai-compatible","auth":{"type":"api-key","store":"opencode","key":"demo"},"enabled":true},
  "unused":{"provider_type":"OpenAICompatible","base_url":"http://unused","api_format":"openai","npm":"@ai-sdk/openai-compatible","auth":{"type":"api-key","store":"opencode","key":"unused"},"enabled":true}
}}
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
m.OPENCODEX_BIN = os.path.join('$TMP', 'opencodex')
for executable in (m.OPENCODEX_BIN,):
    with open(executable, 'w') as handle:
        handle.write('#!/bin/sh\n')
    os.chmod(executable, 0o700)
assert m._provider_consumer_modules() == ['opencodex', 'providers']
m.REGISTRY_PATH = fixture_registry
servers = m._load_servers()
assert set(servers) == {'demo', 'unused'}
assert servers['demo']['baseURL'] == 'http://demo'
assert servers['demo']['models'] == []
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

# The canonical registry routes only through its provider object.
canonical = copy.deepcopy(m.load_json('$ROOT/files/provider-registry.json'))
assert 'profiles' not in canonical
serialized = json.dumps(canonical).lower()
for legacy_field in ('default_model', 'haiku', 'sonnet', 'opus'):
    assert legacy_field not in serialized
retired = m.load_json('$ROOT/files/claudex-profiles.json')
assert 'providers' not in retired
assert isinstance(retired.get('profiles'), list) and retired['profiles']
m._validate_registry(canonical)
m.save_json(m.REGISTRY_PATH + '.canonical', canonical)
original_registry, m.REGISTRY_PATH = m.REGISTRY_PATH, m.REGISTRY_PATH + '.canonical'
assert set(m._load_servers()) == {'grimoire', 'crofai', 'commandcode', 'deepseek', 'kimicode', 'meta'}
m.REGISTRY_PATH = original_registry

# The registry is fetched unverified, so validation is the only gate: missing
# providers and legacy profile-only shapes must be refused.
for empty in ({'version': 1}, {'version': 1, 'providers': {}}, {'version': 1, 'profiles': []},
              {'version': 1, 'profiles': [{'name': 'demo'}]}):
    try:
        m._validate_registry(copy.deepcopy(empty))
    except ValueError:
        pass
    else:
        raise AssertionError(f'content-free registry passed validation: {empty}')
m._validate_registry(m.load_json('$ROOT/files/provider-registry.json'))
m._validate_registry(copy.deepcopy(canonical))
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
models = m.refresh_server('demo', servers['demo'])
assert models
assert m.load_json(m.OPENCODE_PATH)['provider']['demo']['models'] == {
    'fresh-1': {'limit': {'context': 32768, 'output': 16384},
                'cost': {'input': 0, 'output': 0, 'cache_read': 0}},
    'fresh-2': {'limit': {'context': 32768, 'output': 16384},
                'cost': {'input': 0, 'output': 0, 'cache_read': 0}},
    'stale-1': {'limit': {'context': 32768, 'output': 16384},
                'cost': {'input': 0, 'output': 0, 'cache_read': 0}},
}

# Some OpenAI-compatible endpoints do not implement GET /models. A provider's
# registry-owned list is authoritative in that case and uses the same mirrors.
static = copy.deepcopy(servers['demo'])
static['models'] = [{'id': '@vendor/model'}]
m.fetch_models = lambda *_: (_ for _ in ()).throw(
    AssertionError('static provider fetched /models')
)
static_models = m.refresh_server('demo', static)
assert list(static_models) == ['@vendor/model']
assert '@vendor/model' in m.load_json(m.OPENCODE_PATH)['provider']['demo']['models']
# The single-provider refresh path in main() mirrors after the fetch.
m._sync_hermes_mirror(servers, {'demo': models})
mirrored = _load_yaml(m.HERMES_CONFIG)
# unused (disabled) is removed by the status-reflecting mirror; ghost (unknown
# to the registry) is never touched; foreign likewise.
assert [e['name'] for e in mirrored['custom_providers']] == ['demo', 'foreign', 'ghost'], [e['name'] for e in mirrored['custom_providers']]
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
assert mirrored['custom_providers'][2] == {
    'name': 'ghost',
    'base_url': 'http://ghost',
    'api_key': 'ghost-key',
    'models': ['ghost-model'],
}
assert _os.stat(m.HERMES_CONFIG).st_ino != before_inode  # atomic replace

# Idempotent: an unchanged mirror rewrites nothing.
before_mtime = _os.stat(m.HERMES_CONFIG).st_mtime
m._sync_hermes_mirror(servers, {'demo': {'fresh-1': {}, 'fresh-2': {}, 'stale-1': {}}})
assert _os.stat(m.HERMES_CONFIG).st_mtime == before_mtime

# A refreshed list without models leaves the entry untouched: demo is enabled
# but has no refreshed data this run — the entry keeps its previous models
# (offline tolerance; never clobbered, never removed).
m.cache_remove('demo')
m.fetch_models = lambda base, auth: {'data': [{'id': 'fresh-3'}]}
m.cache_set('demo', 'demo-key')
m._sync_hermes_mirror(servers, {})
assert _load_yaml(m.HERMES_CONFIG)['custom_providers'][0]['models'] == [
    'fresh-1', 'fresh-2', 'stale-1'
]
# Missing PyYAML skips silently instead of crashing the mirror.
m.fetch_models = lambda base, auth: {'data': [{'id': 'fresh-3'}]}
m.cache_set('demo', 'demo-key')
import builtins
real_import = __import__
def fake_import(name, *args, **kwargs):
    if name == 'yaml':
        raise ImportError('no PyYAML')
    return real_import(name, *args, **kwargs)
builtins.__dict__['__import__'] = fake_import
m._sync_hermes_mirror(servers, {'demo': {'fresh-3': {}}})  # mirror skipped
builtins.__dict__['__import__'] = real_import
# The file content is still the previous mirrored list (mirror skipped).
assert _load_yaml(m.HERMES_CONFIG)['custom_providers'][0]['models'] == [
    'fresh-1', 'fresh-2', 'stale-1'
]

# An unparseable Hermes config skips silently and is never overwritten.
with open(m.HERMES_CONFIG, 'w') as handle:
    handle.write('custom_providers: [broken\n')
m._sync_hermes_mirror(servers, {'demo': {'fresh-3': {}}})
assert open(m.HERMES_CONFIG).read() == 'custom_providers: [broken\n'
with open(m.HERMES_CONFIG, 'w') as handle:
    handle.write('custom_providers:\n  - name: demo\n    models:\n      - stale-1\n')

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
captured = {}
m._provision_provider = lambda provider, token: captured.update(provider=provider, token=token)
m._add_provider()
assert captured['provider']['name'] == 'added'
assert set(captured['provider']) == {
    'name', 'provider_type', 'base_url', 'auth', 'enabled', 'api_format', 'npm'
}
assert captured['token'] == 'secret-token'

# Agents can add a provider directly without any prompts. The endpoint is
# normalized before it is published, and the token is never printed.
answers = iter(['static', 'https://static.invalid/v1', '@vendor/static', 'y'])
builtins.input = lambda prompt='': next(answers)
m.fetch_models = lambda base, auth: None
captured = {}
m._provision_provider = lambda provider, token: captured.update(provider=provider, token=token)
m._add_provider()
assert captured['provider']['models'] == [{'id': '@vendor/static'}]
assert captured['token'] == 'secret-token'

import contextlib, io
builtins.input = lambda prompt='': (_ for _ in ()).throw(AssertionError(f'unexpected prompt: {prompt}'))
m.getpass.getpass = builtins.input
m.fetch_models = lambda base, auth: {'data': [{'id': 'small'}, {'id': 'large'}]}
captured.clear()
sys.argv = [path, 'add', 'agent-added', 'https://agent-added.invalid/v1/', 'agent-token']
add_output = io.StringIO()
with contextlib.redirect_stdout(add_output):
    m.main()
assert captured['provider']['name'] == 'agent-added'
assert captured['provider']['base_url'] == 'https://agent-added.invalid/v1'
assert captured['token'] == 'agent-token'
assert 'agent-token' not in add_output.getvalue()

m.fetch_models = lambda base, auth: None
captured.clear()
sys.argv = [
    path,
    'add',
    'agent-static',
    'https://agent-static.invalid/v1',
    'agent-token',
    '@vendor/static',
]
with contextlib.redirect_stdout(add_output):
    m.main()
assert captured['provider']['models'] == [{'id': '@vendor/static'}]

timer_output = io.StringIO()
m._is_macos = lambda: True
with contextlib.redirect_stdout(timer_output):
    m.cmd_timer_status()
assert timer_output.getvalue().strip() == 'timer: not installed'

# The command tree is explicit: provider state and timer control are separate
# branches, and the former nested namespace plus argument-less timer commands
# are rejected.
dispatch = []
m._set_provider_enabled = lambda name, enabled: dispatch.append((name, enabled)) or True
m.cmd_timer_enable = lambda: dispatch.append(('timer', 'enable'))
m.cmd_timer_disable = lambda: dispatch.append(('timer', 'disable'))
m.cmd_timer_status = lambda: dispatch.append(('timer', 'status'))
for argv in ([path, 'enable', 'demo'], [path, 'disable', 'demo'],
             [path, 'timer', 'enable'], [path, 'timer', 'disable'],
             [path, 'timer', 'status']):
    sys.argv = argv
    m.main()
assert dispatch == [
    ('demo', True), ('demo', False), ('timer', 'enable'),
    ('timer', 'disable'), ('timer', 'status')
]
for argv in ([path, 'provider', 'add'], [path, 'add', 'only-name'], [path, 'enable'],
             [path, 'disable'], [path, 'status']):
    sys.argv = argv
    try:
        m.main()
    except SystemExit as exc:
        assert exc.code == 1
    else:
        raise AssertionError(f'removed command form was accepted: {argv}')

with open(m.STATE_PATH, 'w') as handle:
    handle.write('{truncated')
assert not m._provider_enabled('demo', servers['demo'])

# An unreadable migration source is never deleted.
os.remove(m.STATE_PATH)
with open(m.LEGACY_STATE_PATH, 'w') as handle:
    handle.write('{truncated')
assert m._load_provider_state() is None
assert os.path.exists(m.LEGACY_STATE_PATH)

# Status reflection: the mirror reconciles Hermes custom_providers against
# enablement. Re-seed a controlled fixture, then assert:
#   - enabled + refreshed      -> entry upserted (created when missing)
#   - disabled                 -> entry removed
#   - enabled + no refresh     -> entry left untouched (offline tolerance)
#   - unknown (not in servers) -> never touched
with open(m.HERMES_CONFIG, 'w') as handle:
    handle.write('custom_providers:\n'
                 '  - name: demo\n'
                 '    base_url: http://old-demo\n'
                 '    api_key: old-key\n'
                 '    model: old-model\n'
                 '    models: [stale-1, stale-2]\n'
                 '  - name: unused\n'
                 '    base_url: http://old-unused\n'
                 '    api_key: unused-key\n'
                 '    models: [stale-3]\n'
                 '  - name: ghost\n'
                 '    base_url: http://ghost\n'
                 '    api_key: ghost-key\n'
                 '    models: [ghost-model]\n')
# The mirror needs the full managed set: the fixture registry's demo+unused
# merged onto the real registry's providers (demo enabled, unused disabled).
fixture_providers = m.load_json(fixture_registry)['providers']
full_registry = copy.deepcopy(m.load_json('$ROOT/files/provider-registry.json'))
full_registry.setdefault('providers', {}).update(fixture_providers)
full_servers = m._servers_from_registry(full_registry)
assert set(full_servers) >= {'demo', 'unused', 'grimoire', 'crofai'}
# Ensure enablement state for the fixture providers: demo enabled, unused disabled.
m.save_json_atomic(m.STATE_PATH, {'version': 1, 'providers': {}})
state = m.load_json(m.STATE_PATH)
state['providers']['demo'] = {'enabled': True}
state['providers']['unused'] = {'enabled': False}
m.save_json_atomic(m.STATE_PATH, state)
m.cache_set('demo', 'demo-key')
m.cache_set('unused', 'unused-key')

# Enabled + refreshed -> demo entry updated (models/base_url/api_key),
# unused (disabled) removed, ghost (unknown) untouched.
m._sync_hermes_mirror(full_servers, {'demo': {'fresh-1': {}, 'fresh-2': {}}})
mirrored = _load_yaml(m.HERMES_CONFIG)
names = [e['name'] for e in mirrored['custom_providers']]
assert names == ['demo', 'ghost'], names
demo = mirrored['custom_providers'][0]
assert demo['models'] == ['fresh-1', 'fresh-2'], demo
assert demo['base_url'] == 'http://demo', demo
assert demo['api_key'] == 'demo-key', demo
assert demo['model'] == 'old-model'  # unrelated fields preserved
assert mirrored['custom_providers'][1]['name'] == 'ghost'
assert mirrored['custom_providers'][1]['models'] == ['ghost-model']

# Enabled + no refreshed data this run: the entry is left untouched (the
# provider may simply be offline), not removed and not clobbered.
m._sync_hermes_mirror(full_servers, {})
mirrored = _load_yaml(m.HERMES_CONFIG)
assert [e['name'] for e in mirrored['custom_providers']] == ['demo', 'ghost']
assert mirrored['custom_providers'][0]['models'] == ['fresh-1', 'fresh-2']

# An enabled provider with NO existing entry is created (mirror-all-enabled).
m._sync_hermes_mirror(full_servers, {'unused': {'u1': {}}})
# ... but unused is disabled, so it is removed, not created. Re-enable it:
state = m.load_json(m.STATE_PATH)
state['providers']['unused'] = {'enabled': True}
m.save_json_atomic(m.STATE_PATH, state)
m._sync_hermes_mirror(full_servers, {'unused': {'u1': {}}})
mirrored = _load_yaml(m.HERMES_CONFIG)
names = [e['name'] for e in mirrored['custom_providers']]
assert 'unused' in names, names
unused = next(e for e in mirrored['custom_providers'] if e['name'] == 'unused')
assert unused['models'] == ['u1'], unused
assert unused['base_url'] == 'http://unused', unused
assert unused['api_key'] == 'unused-key', unused

# Naming convention: only {PROVIDER}_API_KEY items are conforming.
assert m._conforming_item_name('DEEPSEEK_API_KEY')
assert m._conforming_item_name('OPENCODE_GO_API_KEY')
assert not m._conforming_item_name('VAST.AI API KEY')
assert not m._conforming_item_name('GITHUB_COPILOT_OAUTH_TOKEN')
assert not m._conforming_item_name('deepseek_api_key')
PY

echo "providers tests passed"
