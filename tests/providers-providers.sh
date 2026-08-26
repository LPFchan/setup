#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export PROVIDERS_REGISTRY="$TMP/registry.json"
export PROVIDER_STATE_PATH="$HOME/.config/providers/state.json"
export PROVIDERS_CACHE_PATH="$HOME/.config/providers/credentials.json"
export PROVIDERS_CAPABILITIES_PATH="$HOME/.config/providers/capabilities.json"
mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode"
printf '{"provider":{"foreign":{}},"disabled_providers":["foreign-disabled"]}\n' > "$HOME/.config/opencode/opencode.json"
printf '{"demo":{"type":"api","key":"demo-key"}}\n' > "$HOME/.local/share/opencode/auth.json"
export HERMES_CONFIG="$HOME/.hermes/config.yaml"
export PI_MODELS_PATH="$HOME/.pi/agent/models.json"
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
assert set(m._load_servers()) == {
    'grimoire', 'crofai', 'commandcode', 'deepseek', 'kimicode', 'meta',
    'cloudflare', 'openrouter'
}
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
openrouter = canonical['providers']['openrouter']
assert openrouter == {
    'provider_type': 'OpenAICompatible',
    'base_url': 'https://openrouter.ai/api/v1',
    'api_format': 'openai',
    'npm': '@ai-sdk/openai-compatible',
    'auth': {'type': 'api-key', 'store': 'opencode', 'key': 'openrouter'},
    'enabled': True,
}
serialized = json.dumps(canonical).lower()
for legacy_field in ('default_model', 'haiku', 'sonnet', 'opus'):
    assert legacy_field not in serialized
retired = m.load_json('$ROOT/files/claudex-profiles.json')
assert 'providers' not in retired
assert isinstance(retired.get('profiles'), list) and retired['profiles']
m._validate_registry(canonical)
m.save_json(m.REGISTRY_PATH + '.canonical', canonical)
original_registry, m.REGISTRY_PATH = m.REGISTRY_PATH, m.REGISTRY_PATH + '.canonical'
assert set(m._load_servers()) == {
    'grimoire', 'crofai', 'commandcode', 'deepseek', 'kimicode', 'meta',
    'cloudflare', 'openrouter'
}
m.REGISTRY_PATH = original_registry

# OpenRouter uses the shared OpenAI-compatible adapter and resolves its
# canonical credential reference through the local cache. No volatile model
# capability metadata is stored in the registry: model refresh is live.
canonical_servers = m._servers_from_registry(canonical)
openrouter_server = canonical_servers['openrouter']
assert openrouter_server == {
    'baseURL': 'https://openrouter.ai/api/v1',
    'api_format': 'openai',
    'npm': '@ai-sdk/openai-compatible',
    'auth': {'type': 'auth_json', 'provider': 'openrouter'},
    'registry_enabled': True,
    'models': [],
}
m.cache_set('openrouter', 'fixture-openrouter-token')
assert m.get_auth(openrouter_server['auth']) == ('api_key', 'fixture-openrouter-token')
fetch_calls = []
def fake_openrouter_fetch(base_url, auth):
    fetch_calls.append((base_url, auth, m.get_auth(auth)))
    return {'data': [{'id': 'openrouter/test-model'}]}
m.fetch_models = fake_openrouter_fetch
openrouter_models = m.refresh_server('openrouter', openrouter_server)
assert fetch_calls == [
    (
        'https://openrouter.ai/api/v1',
        {'type': 'auth_json', 'provider': 'openrouter'},
        ('api_key', 'fixture-openrouter-token'),
    )
]
assert list(openrouter_models) == ['openrouter/test-model']
assert m.load_json(m.OPENCODE_PATH)['provider']['openrouter']['models'] == {
    'openrouter/test-model': {
        'limit': {'context': 32768, 'output': 16384},
        'cost': {'input': 0, 'output': 0, 'cache_read': 0},
    }
}

# Capability snapshots retain exact native OpenRouter metadata while making
# unknown and malformed advertisements explicit.  The endpoint is sanitized
# before durable state is written, and the fingerprint ignores source JSON
# key order and volatile provenance fields.
openrouter_row = {
    'id': 'openrouter/native-reasoning',
    'architecture': {'input_modalities': ['text', 'image']},
    'supported_parameters': ['temperature', 'reasoning'],
    'reasoning': {
        'mandatory': False,
        'default_enabled': True,
        'supported_efforts': ['low', 'medium', 'high'],
        'default_effort': 'medium',
    },
    'context_length': 131072,
    'max_completion_tokens': 8192,
    'pricing': {'prompt': '1.0', 'completion': '2.0'},
}
snapshot = m._capability_snapshot(
    'openrouter',
    {'baseURL': 'https://token:secret@example.invalid/api/v1'},
    payload={'data': [openrouter_row]},
    rows=[openrouter_row],
)
record = snapshot['models']['openrouter/native-reasoning']
assert record['provider'] == 'openrouter'
assert record['id'] == 'openrouter/native-reasoning'
assert record['input_modalities'] == {'state': 'known', 'values': ['image', 'text']}
assert record['supported_parameters'] == {
    'state': 'known', 'values': ['reasoning', 'temperature']
}
assert record['reasoning'] == {
    'support': 'full',
    'supported_efforts': ['low', 'medium', 'high'],
    'default_effort': 'medium',
    'default_enabled': True,
    'mandatory': False,
}
assert record['context'] == 131072 and record['output'] == 8192
assert record['cost'] == {'input': 1.0, 'output': 2.0, 'cache_read': None}
assert record['source_endpoint'] == 'https://example.invalid/api/v1/models'
assert record['evidence_source'] == 'provider_models_endpoint'
assert 'secret' not in json.dumps(snapshot)
m._update_capability_cache('openrouter', snapshot)
before_capabilities = open('$HOME/.config/providers/capabilities.json', 'rb').read()
assert not m._update_capability_cache('openrouter', dict(snapshot, models={}))
assert open('$HOME/.config/providers/capabilities.json', 'rb').read() == before_capabilities
assert oct(os.stat('$HOME/.config/providers/capabilities.json').st_mode & 0o777) == '0o600'

# A corrupt capability cache is quarantined without making the read path
# unusable, and static registry models carry explicit unknown capability data.
with open('$HOME/.config/providers/capabilities.json', 'w') as handle:
    handle.write('{truncated')
assert m._load_capabilities() == {'version': 1, 'providers': {}}
assert os.path.exists('$HOME/.config/providers/capabilities.json.corrupt')
static_snapshot = m._capability_snapshot(
    'demo', {'baseURL': 'https://demo.invalid/v1'},
    rows=[{'id': 'static-model'}], static=True,
)
static_record = static_snapshot['models']['static-model']
assert static_record['reasoning']['support'] == 'unknown'
assert static_record['input_modalities']['state'] == 'unknown'
assert static_record['evidence_source'] == 'provider_registry_static_models'
m._update_capability_cache('openrouter', snapshot)

empty_reasoning = m.normalize_model_row(
    'demo', 'empty-reasoning', {'id': 'empty-reasoning', 'reasoning': {}},
    'https://demo.invalid/models', '2026-08-27T00:00:00Z', 'a' * 64,
)
assert empty_reasoning['reasoning']['support'] == 'unknown'
numeric_row = m.normalize_model_row(
    'demo', 'numeric-values', {
        'id': 'numeric-values', 'context_length': '131072',
        'max_completion_tokens': '8192',
        'pricing': {'prompt': '0.25', 'completion': '1.5'},
    }, 'https://demo.invalid/models', '2026-08-27T00:00:00Z', 'a' * 64,
)
assert numeric_row['context'] == 131072 and isinstance(numeric_row['context'], int)
assert numeric_row['output'] == 8192 and isinstance(numeric_row['output'], int)
assert numeric_row['cost'] == {'input': 0.25, 'output': 1.5, 'cache_read': None}

# Nested cache containers are validated before a machine consumer can read
# them, then quarantined like a corrupt top-level document.
with open('$HOME/.config/providers/capabilities.json', 'w') as handle:
    json.dump({'version': 1, 'providers': {'openrouter': {'models': []}}}, handle)
assert m._load_capabilities() == {'version': 1, 'providers': {}}
assert os.path.exists('$HOME/.config/providers/capabilities.json.corrupt')
m._update_capability_cache('openrouter', snapshot)

for row, support in (
    ({'id': 'generic/full', 'supported_reasoning_levels': [
        {'effort': 'low'}, {'effort': 'medium'}, {'effort': 'high'}]}, 'full'),
    ({'id': 'generic/think', 'think_efforts': {
        'values': ['tiny', 'huge']}}, 'full'),
    ({'id': 'generic/partial', 'supports_reasoning': True}, 'partial'),
    ({'id': 'generic/none', 'supports_reasoning': False}, 'none'),
    ({'id': 'generic/unknown'}, 'unknown'),
):
    normalized = m.normalize_model_row(
        'demo', row['id'], row, 'https://demo.invalid/models',
        '2026-08-27T00:00:00Z', 'b' * 64,
    )
    assert normalized['reasoning']['support'] == support, normalized
assert m.normalize_model_row(
    'demo', 'generic/bad',
    {'id': 'generic/bad', 'supported_reasoning_levels': [{'effort': 7}]},
    'https://demo.invalid/models', '2026-08-27T00:00:00Z', 'c' * 64,
)['reasoning']['support'] == 'unknown'
assert m.normalize_model_row(
    'demo', 'generic/bad-modalities',
    {'id': 'generic/bad-modalities', 'architecture': {'input_modalities': ['text', 7]}},
    'https://demo.invalid/models', '2026-08-27T00:00:00Z', 'd' * 64,
)['input_modalities']['state'] == 'unknown'

row_a = {'id': 'generic/fingerprint', 'supported_parameters': ['b', 'a'],
         'architecture': {'input_modalities': ['text', 'image']},
         'reasoning': {'supported_efforts': ['low', 'high']}}
row_b = {'reasoning': {'supported_efforts': ['low', 'high']},
         'architecture': {'input_modalities': ['text', 'image']},
         'supported_parameters': ['a', 'b'], 'id': 'generic/fingerprint'}
fp_a = m.normalize_model_row('demo', row_a['id'], row_a,
    'https://demo.invalid/models', '2026-08-27T00:00:00Z', 'e' * 64)['metadata_fingerprint']
fp_b = m.normalize_model_row('demo', row_b['id'], row_b,
    'https://demo.invalid/models', '2026-08-28T00:00:00Z', 'f' * 64)['metadata_fingerprint']
assert fp_a == fp_b

# The read-only machine interface emits JSON only on stdout and filters an
# exact model view.  It does not refresh or inspect credentials.
import contextlib, io
cap_output = io.StringIO()
with contextlib.redirect_stdout(cap_output):
    m.cmd_capabilities(['show', '--provider', 'openrouter',
                        '--model', 'openrouter/native-reasoning', '--json'])
view = json.loads(cap_output.getvalue())
assert list(view['providers']) == ['openrouter']
assert list(view['providers']['openrouter']['models']) == ['openrouter/native-reasoning']
assert 'secret' not in cap_output.getvalue()
subprocess_result = __import__('subprocess').run(
    [sys.executable, path, 'capabilities', 'show', '--provider', 'openrouter',
     '--model', 'openrouter/native-reasoning', '--json'],
    text=True, capture_output=True, check=True,
)
assert set(json.loads(subprocess_result.stdout)['providers']['openrouter']['models']) == {
    'openrouter/native-reasoning'
}
assert subprocess_result.stderr == ''

# A real subprocess refresh uses one fixture HTTP response, emits only the
# selected normalized view on stdout, and never prints the credential. A later
# failed refresh leaves that provider's snapshot byte-for-byte unchanged.
import http.server, threading
class CapabilityHandler(http.server.BaseHTTPRequestHandler):
    calls = 0
    empty = False
    def do_GET(self):
        type(self).calls += 1
        assert self.path == '/v1/models'
        assert self.headers.get('Authorization') == 'Bearer refresh-secret-token'
        payload = {'data': []} if type(self).empty else {'data': [{
            'id': 'refresh-model',
            'architecture': {'input_modalities': ['text', 'image']},
            'supported_parameters': ['reasoning'],
            'reasoning': {'supported_efforts': ['native-low', 'native-high'],
                          'default_effort': 'native-low',
                          'default_enabled': True, 'mandatory': False},
            'context_length': '64000', 'max_completion_tokens': '4000',
            'pricing': {'prompt': '0.1', 'completion': '0.2'},
        }]}
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass

server = http.server.HTTPServer(('127.0.0.1', 0), CapabilityHandler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
refresh_registry = '$TMP/refresh-registry.json'
refresh_base = f'http://127.0.0.1:{server.server_port}/v1'
with open(refresh_registry, 'w') as handle:
    json.dump({'version': 1, 'providers': {'demo': {
        'provider_type': 'OpenAICompatible', 'base_url': refresh_base,
        'api_format': 'openai', 'npm': '@ai-sdk/openai-compatible',
        'auth': {'type': 'api-key', 'store': 'opencode', 'key': 'demo'},
        'enabled': True}}}, handle)
m.cache_set('demo', 'refresh-secret-token')
refresh_env = os.environ.copy()
refresh_env['PROVIDERS_REGISTRY'] = refresh_registry
refresh_command = [sys.executable, path, 'capabilities', 'refresh',
                   '--provider', 'demo', '--model', 'refresh-model', '--json']
first_refresh = __import__('subprocess').run(
    refresh_command, env=refresh_env, text=True, capture_output=True, check=True)
assert CapabilityHandler.calls == 1, CapabilityHandler.calls
refresh_view = json.loads(first_refresh.stdout)
refresh_record = refresh_view['providers']['demo']['models']['refresh-model']
assert refresh_record['reasoning']['supported_efforts'] == ['native-low', 'native-high']
assert refresh_record['context'] == 64000 and refresh_record['output'] == 4000
assert refresh_record['cost'] == {'input': 0.1, 'output': 0.2, 'cache_read': None}
assert 'refresh-secret-token' not in first_refresh.stdout
assert 'refresh-secret-token' not in first_refresh.stderr
capability_bytes_before_failed_refresh = open('$HOME/.config/providers/capabilities.json', 'rb').read()
CapabilityHandler.empty = True
failed_refresh = __import__('subprocess').run(
    refresh_command, env=refresh_env, text=True, capture_output=True)
assert failed_refresh.returncode != 0
assert CapabilityHandler.calls == 2, CapabilityHandler.calls
assert open('$HOME/.config/providers/capabilities.json', 'rb').read() == capability_bytes_before_failed_refresh
server.shutdown()
m._sync_pi_models_mirror(canonical_servers, {'openrouter': openrouter_models})
assert m.load_json(m.PI_MODELS_PATH)['providers']['openrouter']['models'] == [
    {
        'id': 'openrouter/native-reasoning',
        'name': 'openrouter/native-reasoning',
        'contextWindow': 131072,
        'maxTokens': 8192,
        'cost': {'input': 1.0, 'output': 2.0, 'cacheRead': 0, 'cacheWrite': 0},
        'input': ['image', 'text'],
        'reasoning': True,
        'thinkingLevelMap': {'low': 'low', 'medium': 'medium', 'high': 'high'},
    }
]
# An empty live inventory must not erase the last known OpenRouter catalog.
m.fetch_models = lambda *_: {'data': []}
assert m.refresh_server('openrouter', openrouter_server) is False
assert m.load_json(m.OPENCODE_PATH)['provider']['openrouter']['models'] == {
    'openrouter/test-model': {
        'limit': {'context': 32768, 'output': 16384},
        'cost': {'input': 0, 'output': 0, 'cache_read': 0},
    }
}

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

# Miniharness/Pi receives the same successful live inventory. Unrelated
# providers and provider-owned defaults/tiers survive the projection.
os.makedirs(os.path.dirname(m.PI_MODELS_PATH), exist_ok=True)
m._update_capability_cache('demo', m._capability_snapshot(
    'demo', servers['demo'],
    rows=[{'id': model_id} for model_id in ('fresh-1', 'fresh-2', 'stale-1')],
    static=True,
))
m.save_json(m.PI_MODELS_PATH, {
    '_comment': 'preserve me',
    'providers': {
        'demo': {'default_model': 'fresh-1', 'tiers': {'haiku': 'fresh-1'}, 'models': []},
        'foreign': {'base_url': 'http://foreign', 'models': [{'id': 'foreign-model'}]},
    },
})
m._sync_pi_models_mirror(servers, {'demo': models})
pi_models = m.load_json(m.PI_MODELS_PATH)
assert pi_models['_comment'] == 'preserve me'
assert pi_models['providers']['foreign'] == {
    'base_url': 'http://foreign', 'models': [{'id': 'foreign-model'}]
}
pi_demo = pi_models['providers']['demo']
assert pi_demo['default_model'] == 'fresh-1'
assert pi_demo['tiers'] == {'haiku': 'fresh-1'}
assert pi_demo['base_url'] == 'http://demo'
assert pi_demo['provider_type'] == 'OpenAICompatible'
assert pi_demo['models'] == [
    {
        'id': model_id,
        'name': model_id,
        'contextWindow': 32768,
        'maxTokens': 16384,
        'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
    }
    for model_id in ('fresh-1', 'fresh-2', 'stale-1')
]
pi_before = open(m.PI_MODELS_PATH, 'rb').read()
m._sync_pi_models_mirror(servers, {'demo': models})
assert open(m.PI_MODELS_PATH, 'rb').read() == pi_before
m._sync_pi_models_mirror(servers, {})
assert open(m.PI_MODELS_PATH, 'rb').read() == pi_before

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
