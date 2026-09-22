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
import copy, importlib.machinery, importlib.util, json, os, subprocess, sys, time
path = '$ROOT/files/providers'
loader = importlib.machinery.SourceFileLoader('providers_test', path)
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)

# Credential reconciliation is serialized across provider/harness processes,
# while nested cache helpers in one process reuse the outer lock.
with m._consumer_sync_lock():
    with m._consumer_sync_lock():
        pass
locker = subprocess.Popen([
    sys.executable, '-c',
    'import fcntl,sys,time; f=open(sys.argv[1],"a+"); '
    'fcntl.flock(f.fileno(),fcntl.LOCK_EX); print("locked",flush=True); time.sleep(.3)',
    m.CONSUMER_SYNC_LOCK,
], stdout=subprocess.PIPE, text=True)
assert locker.stdout.readline().strip() == 'locked'
started = time.monotonic()
with m._consumer_sync_lock():
    pass
assert time.monotonic() - started >= .2
assert locker.wait() == 0

# Network-optional: no vault token means the local cache is authoritative.
m.vault_available = lambda: False

# Keep the suite offline: an empty catalogue is treated as "already fetched,
# nothing published", so no refresh reaches models.dev.
m._MODELS_DEV_CACHE = {}

# Keep the test hermetic: the real ocx/codex sync must not run from here.
m._sync_opencodex_provider_statuses = lambda restart=True: None

fixture_registry = m.REGISTRY_PATH
m.REGISTRY_PATH = '$ROOT/files/provider-registry.json'
assert set(m._load_servers()) == {
    'grimoire', 'commandcode', 'deepseek', 'kimicode', 'meta',
    'cloudflare', 'openrouter', 'opencode-zen', 'opencode-go'
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
zen = canonical['providers']['opencode-zen']
assert zen['base_url'] == 'https://opencode.ai/zen/v1'
assert zen['auth'] == {
    'type': 'api-key', 'store': 'opencode', 'key': 'opencode-go'
}
assert zen['model_allow_suffixes'] == ['-free', 'alpha']
assert 'big-pickle' in zen['model_allow_ids']
assert 'union-alpha' in zen['model_allow_ids']
assert 'x-preview-f-free' in zen['model_allow_ids']
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
    'grimoire', 'commandcode', 'deepseek', 'kimicode', 'meta',
    'cloudflare', 'openrouter', 'opencode-zen', 'opencode-go'
}
m.REGISTRY_PATH = original_registry

# OpenRouter uses the shared OpenAI-compatible adapter and resolves its
# canonical credential reference through the local cache. No volatile model
# capability metadata is stored in the registry: model refresh is live.
canonical_servers = m._servers_from_registry(canonical)
assert canonical_servers['grimoire']['auth'] == {
    'type': 'common_auth', 'provider': 'grimoire', 'scope': 'chat-v1'
}
m.common_auth_context = lambda: {
    'origin': 'https://auth.lost.plus', 'subject': 'account-a',
}
m.common_auth_token = lambda scope, context=None: 'common-' + scope
m._sync_common_auth(canonical_servers)
assert m.cache_get('grimoire') == 'common-chat-v1'
assert m.VAULT_TOKEN == 'common-passage'

# The hourly timer invokes the bare/list command. A successful Common Auth
# rotation must therefore flow from cache into every credential mirror there.
real_load_servers = m._load_servers
real_sync_common_auth = m._sync_common_auth
real_sync_mirrors = m._sync_mirrors
real_sync_hermes_mirror = m._sync_hermes_mirror
published = []
m._load_servers = lambda: canonical_servers
m._sync_common_auth = lambda current: published.append('auth')
m._sync_mirrors = lambda: published.append('mirrors')
m._sync_hermes_mirror = lambda current, refreshed: published.append('hermes')
m.cmd_ls()
assert published == ['auth', 'mirrors', 'hermes']
m._load_servers = real_load_servers
m._sync_common_auth = real_sync_common_auth
m._sync_mirrors = real_sync_mirrors
m._sync_hermes_mirror = real_sync_hermes_mirror

# A separately managed OpenCode OAuth session is not a Common Auth API bearer.
# Preserve the OAuth record, but never use its access token as a fallback.
m.cache_remove('grimoire')
m.save_json_atomic(m.OLD_AUTH_PATH, {
    'grimoire': {'type': 'api', 'key': 'stale-common-auth-bearer'},
})
m._write_auth_mirror({}, managed_absent={'grimoire'})
assert 'grimoire' not in m.load_json(m.OLD_AUTH_PATH)
m.save_json_atomic(m.OLD_AUTH_PATH, {
    'grimoire': {'type': 'oauth', 'access': 'separate-oauth-session'},
})
assert m._get_common_auth_key('grimoire') == ''
assert m.get_auth(canonical_servers['grimoire']['auth']) == (None, None)
assert m.load_json(m.OLD_AUTH_PATH)['grimoire']['access'] == 'separate-oauth-session'
m.cache_set('grimoire', 'common-chat-v1')
m._sync_mirrors()
preserved_oauth = m.load_json(m.OLD_AUTH_PATH)['grimoire']
assert preserved_oauth == {'type': 'oauth', 'access': 'separate-oauth-session'}
mirrored_env = open(m.ZSENV_PATH).read()
assert 'GRIMOIRE_API_KEY=common-chat-v1' in mirrored_env
assert 'GRIMOIRE_OAUTH_TOKEN=separate-oauth-session' in mirrored_env

# The block's leading separator is rewritten on every pass, so the blank line
# before it must be reclaimed with the old block. It was not, and the file grew
# by one blank line per write; a real .zshenv had reached 180. Repeated writes
# must converge, and an already-bloated file must heal rather than hold.
def _blanks_before_block():
    head = open(m.ZSENV_PATH).read().split(m.AUTH_BLOCK_BEGIN)[0]
    return len(head) - len(head.rstrip('\n'))
with open(m.ZSENV_PATH) as handle:
    bloated = handle.read().replace(m.AUTH_BLOCK_BEGIN, '\n' * 40 + m.AUTH_BLOCK_BEGIN, 1)
with open(m.ZSENV_PATH, 'w') as handle:
    handle.write(bloated)
m._write_env_mirror(m._load_cache())
healed = _blanks_before_block()
m._write_env_mirror(m._load_cache())
assert _blanks_before_block() == healed, (healed, _blanks_before_block())
assert healed <= 2, healed
assert 'GRIMOIRE_API_KEY=common-chat-v1' in open(m.ZSENV_PATH).read()

# If account context cannot be read, do not fetch a potentially different
# login's tokens and then save them under the previous account binding.
contextless_calls = []
m.common_auth_context = lambda: (_ for _ in ()).throw(
    m.CommonAuthError('context timed out in test')
)
def contextless_common(scope, context=None):
    contextless_calls.append((scope, context))
    return 'wrong-account-' + scope
m.common_auth_token = contextless_common
m._sync_common_auth(canonical_servers)
assert contextless_calls == []
assert m.cache_get('grimoire') == 'common-chat-v1'
m.common_auth_context = lambda: {
    'origin': 'https://auth.lost.plus', 'subject': 'account-a',
}
m.common_auth_token = lambda scope, context=None: 'common-' + scope

# Confirmed Common Auth rejection removes managed cached credentials. A
# temporary exception without this flag continues to preserve them. Rejection
# also dominates inherited process values and every setup-managed mirror.
os.environ['GRIMOIRE_API_KEY'] = 'stale-environment-grimoire'
os.environ['PASSAGE_MCP_TOKEN'] = 'stale-environment-vault'
m.save_json_atomic(m.OLD_AUTH_PATH, {
    'demo': {'type': 'api', 'key': 'demo-key'},
    'grimoire': {'type': 'oauth', 'access': 'separate-oauth-session'},
})
with open(m.ZSENV_PATH, 'w') as handle:
    handle.write(f'{m.AUTH_BLOCK_BEGIN}\nexport GRIMOIRE_API_KEY=stale-zshenv-grimoire\n{m.AUTH_BLOCK_END}\n')
with open(m.HERMES_CONFIG, 'a') as handle:
    handle.write('  - name: grimoire\n    api_key: stale-hermes-grimoire\n    models: [stale]\n')
def rejected_common(scope, context=None):
    raise m.CommonAuthError('credential revoked in test', authoritative=True)
m.common_auth_token = rejected_common
m._sync_common_auth(canonical_servers)
assert m.cache_get('grimoire') == ''
assert not m.VAULT_TOKEN
assert 'GRIMOIRE_API_KEY' not in os.environ
assert 'PASSAGE_MCP_TOKEN' not in os.environ
assert m.get_auth(canonical_servers['grimoire']['auth']) == (None, None)
assert 'GRIMOIRE_API_KEY' not in open(m.ZSENV_PATH).read()
assert m.load_json(m.OLD_AUTH_PATH)['grimoire'] == {
    'type': 'oauth', 'access': 'separate-oauth-session',
}
try:
    import yaml
except ImportError:
    yaml = None
if yaml:
    with open(m.HERMES_CONFIG) as handle:
        hermes = yaml.safe_load(handle) or {}
    grimoire = next(entry for entry in hermes.get('custom_providers', [])
                    if entry.get('name') == 'grimoire')
    assert 'api_key' not in grimoire and grimoire['models'] == ['stale']
m.cache_set('grimoire', 'common-chat-v1')
m.common_auth_token = lambda scope, context=None: 'common-' + scope
m._sync_common_auth(canonical_servers)

# Consumer fallbacks are scoped to the Auth account and origin that produced
# them. Account B cannot inherit account A's cache or process environment when
# B's active bearer is currently unreadable.
os.environ['GRIMOIRE_API_KEY'] = 'account-a-environment'
m.common_auth_context = lambda: {
    'origin': 'https://auth.lost.plus', 'subject': 'account-b',
}
def unavailable_common(scope, context=None):
    if scope == 'passage':
        return 'account-b-vault'
    raise m.CommonAuthError('active credential unreadable in test')
m.common_auth_token = unavailable_common
m._sync_common_auth(canonical_servers)
assert m.cache_get('grimoire') == ''
assert m.get_auth(canonical_servers['grimoire']['auth']) == (None, None)
assert m._load_cache()['_common_auth_context']['subject'] == 'account-b'
os.environ['GRIMOIRE_API_KEY'] = 'account-a-old-shell'
m._sync_common_auth(canonical_servers)
assert 'GRIMOIRE_API_KEY' not in os.environ
assert m.get_auth(canonical_servers['grimoire']['auth']) == (None, None)

# One rejected scope must not erase another scope that is merely unavailable.
state_before_mixed = copy.deepcopy(m._load_provider_state())
mixed_state = copy.deepcopy(state_before_mixed)
mixed_state.setdefault('providers', {})['grimoire'] = {'enabled': True}
m.save_json_atomic(m.STATE_PATH, mixed_state)
m.save_json_atomic(m.OLD_AUTH_PATH, {
    'grimoire': {'type': 'api', 'key': 'bound-account-b-grimoire'},
})
if yaml:
    with open(m.HERMES_CONFIG) as handle:
        hermes = yaml.safe_load(handle) or {}
    entries = hermes.setdefault('custom_providers', [])
    grimoire_entry = next((entry for entry in entries
                           if entry.get('name') == 'grimoire'), None)
    if grimoire_entry is None:
        grimoire_entry = {'name': 'grimoire'}
        entries.append(grimoire_entry)
    grimoire_entry.update({
        'api_key': 'bound-account-b-grimoire', 'models': ['bound-model'],
    })
    with open(m.HERMES_CONFIG, 'w') as handle:
        yaml.safe_dump(hermes, handle, sort_keys=False)
def mixed_common(scope, context=None):
    if scope == 'passage':
        raise m.CommonAuthError('vault credential revoked in test', authoritative=True)
    raise m.CommonAuthError('active credential unreadable in test')
m.common_auth_token = mixed_common
m._sync_common_auth(canonical_servers)
assert m.load_json(m.OLD_AUTH_PATH)['grimoire']['key'] == 'bound-account-b-grimoire'
if yaml:
    m.save_json_atomic(m.OLD_AUTH_PATH, {})
    m._sync_common_auth(canonical_servers)
    with open(m.HERMES_CONFIG) as handle:
        hermes = yaml.safe_load(handle) or {}
    grimoire = next(entry for entry in hermes['custom_providers'] if entry.get('name') == 'grimoire')
    assert grimoire['api_key'] == 'bound-account-b-grimoire'
    m._sync_hermes_mirror(canonical_servers, {}, authoritative_missing={'grimoire'})
    with open(m.HERMES_CONFIG) as handle:
        hermes = yaml.safe_load(handle) or {}
    grimoire = next(entry for entry in hermes['custom_providers'] if entry.get('name') == 'grimoire')
    assert 'api_key' not in grimoire and grimoire['models'] == ['bound-model']
    hermes['custom_providers'] = [
        entry for entry in hermes['custom_providers'] if entry.get('name') != 'grimoire'
    ]
    with open(m.HERMES_CONFIG, 'w') as handle:
        yaml.safe_dump(hermes, handle, sort_keys=False)
m.save_json_atomic(m.STATE_PATH, state_before_mixed)

m.common_auth_token = lambda scope, context=None: 'common-' + scope
m._sync_common_auth(canonical_servers)

# A token is accepted only for the context read in the same reconciliation.
# If login changes in between, the whole operation retries under the new one.
contexts = [
    {'origin': 'https://auth.lost.plus', 'subject': 'account-a'},
    {'origin': 'https://auth.lost.plus', 'subject': 'account-b'},
]
m.common_auth_context = lambda: contexts.pop(0) if contexts else {
    'origin': 'https://auth.lost.plus', 'subject': 'account-b',
}
def raced_common(scope, context=None):
    if context['subject'] == 'account-a':
        raise m.CommonAuthContextChanged('login changed in test')
    return 'account-b-' + scope
m.common_auth_token = raced_common
m._sync_common_auth(canonical_servers)
assert m.cache_get('grimoire') == 'account-b-chat-v1'
assert m._load_cache()['_common_auth_context']['subject'] == 'account-b'

# Provider commands never trust a passage token inherited from an old
# shell; they resolve a current context-bound token before using the vault.
os.environ['PASSAGE_MCP_TOKEN'] = 'old-shell-vault'
m.VAULT_TOKEN = 'old-shell-vault'
m.common_auth_context = lambda: {
    'origin': 'https://auth.lost.plus', 'subject': 'account-b',
}
m.common_auth_token = lambda scope, context=None: 'fresh-bound-vault'
assert m._ensure_vault_token(interactive=False) == 'fresh-bound-vault'
assert m.VAULT_TOKEN == 'fresh-bound-vault'

# Importing the old .zshenv mirror cannot put Common Auth-owned keys back into
# the cache before context reconciliation runs.
with open(m.ZSENV_PATH, 'w') as handle:
    handle.write(f'{m.AUTH_BLOCK_BEGIN}\nexport GRIMOIRE_API_KEY=unbound-old\n'
                 f'export OPENROUTER_API_KEY=independent-key\n{m.AUTH_BLOCK_END}\n')
m.cache_remove('grimoire')
m.cache_remove('openrouter')
m._sync_zsenv_to_cache(canonical_servers)
assert m.cache_get('grimoire') == ''
assert m.cache_get('openrouter') == 'independent-key'
m.cache_set('grimoire', 'common-chat-v1')

# passage may still contain the pre-migration copy of a provider token.
# It must not overwrite a provider now owned by Common Auth, while unrelated
# provider credentials continue to refresh from the vault normally.
m.vault_available = lambda: True
m.vault_list_items = lambda: [
    {'name': 'GRIMOIRE_API_KEY'},
    {'name': 'OPENROUTER_API_KEY'},
]
m.vault_get = lambda name: {
    'GRIMOIRE_API_KEY': 'stale-vault-grimoire',
    'OPENROUTER_API_KEY': 'fresh-vault-openrouter',
}[name]
m._sync_cache_from_vault(canonical_servers)
assert m.cache_get('grimoire') == 'common-chat-v1'
assert m.cache_get('openrouter') == 'fresh-vault-openrouter'
openrouter_server = canonical_servers['openrouter']
assert openrouter_server == {
    'baseURL': 'https://openrouter.ai/api/v1',
    'api_format': 'openai',
    'npm': '@ai-sdk/openai-compatible',
    'auth': {'type': 'auth_json', 'provider': 'openrouter'},
    'registry_enabled': True,
    'models': [],
    'model_exclude_prefixes': [],
    'model_allow_suffixes': [],
    'model_allow_ids': [],
    'headers': {},
    'models_dev': '',
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
    'top_provider': {'max_completion_tokens': 8192},
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
# Kimi names the level list think_efforts.valid_efforts. Reading only the
# The values spelling made a model advertising low/high/max look like it had no
# levels at all, which is indistinguishable from a model that has none.
kimi_row = m.normalize_model_row(
    'demo', 'k3-256k', {
        'id': 'k3-256k', 'supports_reasoning': True,
        'think_efforts': {
            'support': True, 'valid_efforts': ['low', 'high', 'max'],
            'default_effort': 'max',
        },
    },
    'https://demo.invalid/models', '2026-08-27T00:00:00Z', 'b' * 64,
)
assert kimi_row['reasoning']['support'] == 'full', 'valid_efforts not read'
assert kimi_row['reasoning']['supported_efforts'] == ['low', 'high', 'max']
assert kimi_row['reasoning']['default_effort'] == 'max'
bad_think = m.normalize_model_row(
    'demo', 'bad-think', {
        'id': 'bad-think',
        'think_efforts': {'valid_efforts': ['low'], 'default_effort': 3},
    },
    'https://demo.invalid/models', '2026-08-27T00:00:00Z', 'c' * 64,
)
assert bad_think['reasoning']['support'] == 'unknown', 'malformed default passed silently'
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

# Grimoire's endpoint advertises USD per million tokens; the shared cache and
# every generated consumer catalog use the OpenRouter-style USD-per-token unit.
grimoire_row = {
    'id': 'qwen3.8-27B-xhigh',
    'cost': {'input': 0.33, 'output': 3.25, 'cache_read': 0.1},
}
normalized_grimoire = m.normalize_model_row(
    'grimoire', grimoire_row['id'], grimoire_row,
    'https://grimoire.invalid/v1/models', '2026-08-27T00:00:00Z', 'a' * 64,
)
import math
for key, expected in {
    'input': 0.00000033,
    'output': 0.00000325,
    'cache_read': 0.0000001,
}.items():
    assert math.isclose(normalized_grimoire['cost'][key], expected)
assert m.model_to_config_grimoire(grimoire_row)['cost'] == normalized_grimoire['cost']

# An output limit of -1 means the provider does not impose a generation cap.
# OpenCode requires a finite positive ceiling, while Miniharness uses -1 to
# preserve unbounded generation for evaluation runs.
unbounded_grimoire_row = {
    'id': 'qwen3.8-27B-xhigh',
    'context': 237568,
    'output': -1,
}
unbounded_grimoire = m.normalize_model_row(
    'grimoire', unbounded_grimoire_row['id'], unbounded_grimoire_row,
    'https://grimoire.invalid/v1/models', '2026-08-27T00:00:00Z', 'a' * 64,
)
assert unbounded_grimoire['output'] == -1
assert m.model_to_config_grimoire(unbounded_grimoire_row)['limit'] == {
    'context': 237568,
    'output': 237568,
}
assert m._pi_model_entry(
    unbounded_grimoire_row['id'],
    m.model_to_config_grimoire(unbounded_grimoire_row),
    unbounded_grimoire,
)['maxTokens'] == -1
assert m.model_to_config_grimoire({
    'id': 'finite-output', 'context': 131072, 'output': 8192,
})['limit']['output'] == 8192

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
    m.cmd_capabilities(['--provider', 'openrouter',
                        '--model', 'openrouter/native-reasoning', '--json'])
view = json.loads(cap_output.getvalue())
assert list(view['providers']) == ['openrouter']
assert list(view['providers']['openrouter']['models']) == ['openrouter/native-reasoning']
assert 'secret' not in cap_output.getvalue()
subprocess_result = __import__('subprocess').run(
    [sys.executable, path, 'capabilities', '--provider', 'openrouter',
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
refresh_command = [sys.executable, path, 'refresh', 'demo']
show_command = [sys.executable, path, 'capabilities',
                '--provider', 'demo', '--model', 'refresh-model', '--json']
first_refresh = __import__('subprocess').run(
    refresh_command, env=refresh_env, text=True, capture_output=True, check=True)
assert CapabilityHandler.calls == 1, CapabilityHandler.calls
first_show = __import__('subprocess').run(
    show_command, env=refresh_env, text=True, capture_output=True, check=True)
refresh_view = json.loads(first_show.stdout)
refresh_record = refresh_view['providers']['demo']['models']['refresh-model']
assert refresh_record['reasoning']['supported_efforts'] == ['native-low', 'native-high']
assert refresh_record['context'] == 64000 and refresh_record['output'] == 4000
assert refresh_record['cost'] == {'input': 0.1, 'output': 0.2, 'cache_read': None}
assert 'refresh-secret-token' not in first_refresh.stdout
assert 'refresh-secret-token' not in first_refresh.stderr
capability_bytes_before_failed_refresh = open('$HOME/.config/providers/capabilities.json', 'rb').read()
CapabilityHandler.empty = True
failed_refresh = __import__('subprocess').run(
    refresh_command, env=refresh_env, text=True, capture_output=True, check=True)
assert CapabilityHandler.calls == 2, CapabilityHandler.calls
assert open('$HOME/.config/providers/capabilities.json', 'rb').read() == capability_bytes_before_failed_refresh
server.shutdown()
# OpenCode Zen admits newly published -free IDs and known free stealth IDs,
# while paid and unknown IDs never reach a consumer mirror.
zen_rows = [
    {'id': 'big-pickle'},
    {'id': 'union-alpha'},
    {'id': 'x-preview-f-free'},
    {'id': 'new-model-free'},
    {'id': 'ox-alpha'},
    {'id': 'future-stealth-alpha'},
    {'id': 'OX-ALPHA'},
    {'id': 'minimax-m3'},
    {'id': 'unknown-stealth'},
]
assert [row['id'] for row in m._filter_models(
    'opencode-zen', canonical_servers['opencode-zen'], zen_rows
)] == [
    'big-pickle', 'union-alpha', 'x-preview-f-free', 'new-model-free',
    'ox-alpha', 'future-stealth-alpha', 'OX-ALPHA'
]
# The same allow policy applies to static model inventories.
assert m._filter_models(
    'opencode-zen', canonical_servers['opencode-zen'],
    [{'id': 'paid-model'}, {'id': 'mimo-v2.5-free'}],
) == [{'id': 'mimo-v2.5-free'}]
# Registry-owned model_exclude_prefixes removes matching ids from a live
# refresh before any mirror sees them. The provider's other models pass
# through unchanged.
m.cache_set('demo', 'demo-key')
m.fetch_models = lambda base, auth: {'data': [
    {'id': 'eastself-a'}, {'id': 'eastself-b'}, {'id': 'keep-1'},
]}
demo_exclude = copy.deepcopy(servers['demo'])
demo_exclude['model_exclude_prefixes'] = ['eastself-']
excluded_models = m.refresh_server('demo', demo_exclude)
assert list(excluded_models) == ['keep-1'], excluded_models
assert list(m.load_json(m.OPENCODE_PATH)['provider']['demo']['models']) == ['keep-1']
# A filter that removes every model is treated as an empty refresh and does
# not replace the last known inventory.
m.fetch_models = lambda base, auth: {'data': [{'id': 'eastself-a'}]}
assert m.refresh_server('demo', demo_exclude) is False
assert list(m.load_json(m.OPENCODE_PATH)['provider']['demo']['models']) == ['keep-1']
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
sys.argv = [path, 'refresh']
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

# Credential rotation is independent from model refresh. A failed /models
# request keeps the known inventory but must still replace an old Hermes key.
m.cache_set('demo', 'rotated-demo-key')
m._sync_hermes_mirror(servers, {})
rotated_entry = _load_yaml(m.HERMES_CONFIG)['custom_providers'][0]
assert rotated_entry['api_key'] == 'rotated-demo-key'
assert rotated_entry['models'] == ['fresh-1', 'fresh-2', 'stale-1']
m.cache_set('demo', 'demo-key')
m._sync_hermes_mirror(servers, {})

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
# The demo enrollment keys its credential by its own name, so no indirection
# is projected; a provider that declares one gets auth_key, and endpoint-
# required headers ride along for Pi-side consumers to substitute.
assert 'auth_key' not in pi_demo
assert 'headers' not in pi_demo
shared = dict(servers['demo'])
shared['auth'] = {'type': 'auth_json', 'provider': 'shared-key'}
shared['headers'] = {'x-opencode-session': '{session_id}'}
m._update_capability_cache('shared', m._capability_snapshot(
    'shared', shared, rows=[{'id': 'fresh-1'}], static=True,
))
m._sync_pi_models_mirror({'shared': shared}, {'shared': models})
pi_shared = m.load_json(m.PI_MODELS_PATH)['providers']['shared']
assert pi_shared['auth_key'] == 'shared-key', pi_shared
assert pi_shared['headers'] == {'x-opencode-session': '{session_id}'}, pi_shared
# Dropping the indirection from the registry must clear the stale projection.
plain = dict(shared)
plain['auth'] = {'type': 'auth_json', 'provider': 'shared'}
plain['headers'] = {}
m._sync_pi_models_mirror({'shared': plain}, {'shared': models})
pi_plain = m.load_json(m.PI_MODELS_PATH)['providers']['shared']
assert 'auth_key' not in pi_plain, pi_plain
assert 'headers' not in pi_plain, pi_plain

# models.dev fills limits an endpoint leaves out, and never overrides a
# reported one. Stub the catalogue so the test stays offline.
m._MODELS_DEV_CACHE = {
    'demo-catalog': {'models': {
        'fresh-1': {'limit': {'context': 1000000, 'output': 384000}},
        'fresh-2': {'limit': {'context': 200000, 'output': 32000}},
    }},
}
enrich_cfg = dict(servers['demo'])
enrich_cfg['models_dev'] = 'demo-catalog'
rows = [
    {'id': 'fresh-1'},                                  # nothing reported
    {'id': 'fresh-2', 'context_length': 4096},          # context reported, output not
    {'id': 'stale-1'},                                  # absent from models.dev
]
enriched = {row['id']: row for row in m._enrich_rows_from_models_dev('demo', enrich_cfg, rows)}
assert enriched['fresh-1']['context_length'] == 1000000, enriched['fresh-1']
assert enriched['fresh-1']['max_completion_tokens'] == 384000, enriched['fresh-1']
# A provider-reported value wins; only the missing half is filled.
assert enriched['fresh-2']['context_length'] == 4096, enriched['fresh-2']
assert enriched['fresh-2']['max_completion_tokens'] == 32000, enriched['fresh-2']
# Unknown to models.dev: left alone for the downstream default to handle.
assert 'context_length' not in enriched['stale-1'], enriched['stale-1']
# The caller's rows are never mutated in place.
assert rows[0] == {'id': 'fresh-1'}, rows[0]
# A provider with no models_dev pointer is untouched, catalogue or not.
assert m._enrich_rows_from_models_dev('demo', servers['demo'], rows) is rows
# An unknown catalogue key degrades to the provider's own data.
missing_cfg = dict(servers['demo'])
missing_cfg['models_dev'] = 'no-such-catalog'
assert m._enrich_rows_from_models_dev('demo', missing_cfg, rows) is rows
m._MODELS_DEV_CACHE = {}
pi_before = open(m.PI_MODELS_PATH, 'rb').read()
m._sync_pi_models_mirror(servers, {'demo': models})
assert open(m.PI_MODELS_PATH, 'rb').read() == pi_before
m._sync_pi_models_mirror(servers, {})
assert open(m.PI_MODELS_PATH, 'rb').read() == pi_before

# Idempotent: an unchanged mirror rewrites nothing.
before_mtime = _os.stat(m.HERMES_CONFIG).st_mtime
m._sync_hermes_mirror(servers, {'demo': {'fresh-1': {}, 'fresh-2': {}, 'stale-1': {}}})
assert _os.stat(m.HERMES_CONFIG).st_mtime == before_mtime

# A refresh without models keeps the previous model list (offline tolerance;
# never clobbered or removed), while credential updates remain independent.
m.cache_remove('demo')
m.fetch_models = lambda base, auth: {'data': [{'id': 'fresh-3'}]}
m.cache_set('demo', 'demo-key')
m._sync_hermes_mirror(servers, {})
assert _load_yaml(m.HERMES_CONFIG)['custom_providers'][0]['models'] == [
    'fresh-1', 'fresh-2', 'stale-1'
]
# Missing PyYAML still replaces and revokes credentials through the supported
# line-oriented fallback; non-secret YAML content remains intact.
m.fetch_models = lambda base, auth: {'data': [{'id': 'fresh-3'}]}
m.cache_set('demo', 'fallback-rotated-key')
with open(m.HERMES_CONFIG, 'w') as handle:
    handle.write('custom_providers:\n'
                 '- api_key: account-a-old-key\n'
                 '  name: demo\n'
                 '  models: [fresh-1, fresh-2, stale-1]\n')
import builtins
real_import = __import__
def fake_import(name, *args, **kwargs):
    if name == 'yaml':
        raise ImportError('no PyYAML')
    return real_import(name, *args, **kwargs)
builtins.__dict__['__import__'] = fake_import
m._sync_hermes_mirror(servers, {})
fallback_text = open(m.HERMES_CONFIG).read()
assert 'fallback-rotated-key' in fallback_text
assert 'fresh-1' in fallback_text and 'fresh-3' not in fallback_text
m._sync_hermes_mirror(servers, {}, authoritative_missing={'demo'})
fallback_revoked = open(m.HERMES_CONFIG).read()
assert 'fallback-rotated-key' not in fallback_revoked
assert 'fresh-1' in fallback_revoked
m.cache_set('demo', 'fallback-restored-key')
m._sync_hermes_mirror(servers, {})
fallback_restored = open(m.HERMES_CONFIG).read()
assert 'fallback-restored-key' in fallback_restored
assert 'fresh-1' in fallback_restored
builtins.__dict__['__import__'] = real_import
# PyYAML can attach a later successful credential to the preserved metadata.
m.cache_set('demo', 'demo-key')
m._sync_hermes_mirror(servers, {})
assert _load_yaml(m.HERMES_CONFIG)['custom_providers'][0]['models'] == [
    'fresh-1', 'fresh-2', 'stale-1'
]
assert _load_yaml(m.HERMES_CONFIG)['custom_providers'][0]['api_key'] == 'demo-key'

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

m._set_key(m._auth_provider('unused', servers['unused']), 'unused-key')
m._set_provider_enabled('unused', True)
assert m.load_json(m.STATE_PATH)['providers']['unused']['enabled'] is True
assert m.load_json(m.OPENCODE_PATH)['disabled_providers'] == ['foreign-disabled']

sys.argv = [path, 'refresh', 'unused']
m.refresh_server = lambda name, cfg: seen.append(name) or True
m.main()
assert seen[-1] == 'unused'

m.REGISTRY_PATH = '$ROOT/files/provider-registry.json'
try:
    m._add_provider('grimoire', 'https://wrong-endpoint.invalid/v1', 'k')
except ValueError as exc:
    assert 'already registered' in str(exc)
else:
    raise AssertionError('provider add allowed an endpoint override on a registry provider')

m.REGISTRY_PATH = fixture_registry
m.fetch_models = lambda base, auth: {'data': [{'id': 'small'}, {'id': 'large'}]}
captured = {}
m._provision_provider = lambda provider, token: captured.update(provider=provider, token=token)
m._add_provider('added', 'https://added.invalid/v1', 'secret-token')
assert captured['provider']['name'] == 'added'
assert set(captured['provider']) == {
    'name', 'provider_type', 'base_url', 'auth', 'enabled', 'api_format', 'npm'
}
assert captured['token'] == 'secret-token'

# Agents can add a provider directly without any prompts. The endpoint is
# normalized before it is published, and the token is never printed.
m.fetch_models = lambda base, auth: None
captured = {}
m._provision_provider = lambda provider, token: captured.update(provider=provider, token=token)
m._add_provider('static', 'https://static.invalid/v1', 'secret-token', '@vendor/static')
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

schedule_output = io.StringIO()
m._is_macos = lambda: True
with contextlib.redirect_stdout(schedule_output):
    m.cmd_schedule_status()
assert schedule_output.getvalue().strip() == 'schedule: not installed'

# The command tree is explicit: provider state and schedule control are
# separate branches, and removed or malformed forms are rejected.
dispatch = []
m._set_provider_enabled = lambda name, enabled: dispatch.append((name, enabled)) or True
m.cmd_schedule_enable = lambda: dispatch.append(('schedule', 'enable'))
m.cmd_schedule_disable = lambda: dispatch.append(('schedule', 'disable'))
m.cmd_schedule_status = lambda: dispatch.append(('schedule', 'status'))
for argv in ([path, 'enable', 'demo'], [path, 'disable', 'demo'],
             [path, 'schedule'], [path, 'schedule', 'disable'],
             [path, 'schedule', 'status']):
    sys.argv = argv
    m.main()
assert dispatch == [
    ('demo', True), ('demo', False), ('schedule', 'enable'),
    ('schedule', 'disable'), ('schedule', 'status')
]
for argv in ([path, 'timer'], [path, 'auth'], [path, 'sync'], [path, 'audit'],
             [path, 'rename'], [path, 'ls'], [path, 'list'], [path, '--list'],
             [path, 'add', 'only-name'], [path, 'enable'], [path, 'disable'],
             [path, 'schedule', 'bogus'], [path, 'unused']):
    sys.argv = argv
    try:
        m.main()
    except SystemExit as exc:
        assert exc.code == 1, argv
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
assert set(full_servers) >= {'demo', 'unused', 'grimoire', 'commandcode'}
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

# Enabled + no refreshed data this run: the model list is left untouched (the
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

# A retired provider is swept off the machine. Every write path here is an
# upsert, so without the sweep a withdrawn provider keeps its credential and
# its model list in every consumer config forever.
m.cache_set('ghost', 'ghost-key')
state = m.load_json(m.STATE_PATH)
state['providers']['ghost'] = {'enabled': True}
m.save_json_atomic(m.STATE_PATH, state)
opencode = m.load_json(m.OPENCODE_PATH)
opencode.setdefault('provider', {})['ghost'] = {'options': {'apiKey': 'ghost-key'}}
opencode['disabled_providers'] = ['foreign-disabled', 'ghost']
m.save_json_atomic(m.OPENCODE_PATH, opencode)
caps = m._load_capabilities()
_endpoint, _when, _digest = 'http://ghost/v1', '2026-01-01T00:00:00Z', '0' * 64
caps.setdefault('providers', {})['ghost'] = {
    'provider': 'ghost', 'source_endpoint': _endpoint, 'fetched_at': _when,
    'raw_response_sha256': _digest, 'evidence_source': 'live',
    'models': {'g1': {
        'provider': 'ghost', 'id': 'g1', 'source_endpoint': _endpoint,
        'fetched_at': _when, 'raw_response_sha256': _digest,
        'metadata_fingerprint': _digest,
    }},
}
m._save_capabilities(caps)
m._write_env_mirror(m._load_cache())
assert 'export GHOST_API_KEY=ghost-key' in open(m.ZSENV_PATH).read()
# auth.json must actually hold the key before the sweep, or the assertion below
# passes on the cache pop alone and never exercises the auth.json path at all.
m._write_auth_mirror(m._load_cache())
assert m.load_json(m.OLD_AUTH_PATH)['ghost'] == {'type': 'api', 'key': 'ghost-key'}
# An OAuth entry is re-exported as {NAME}_OAUTH_TOKEN on every pass, so the
# whole entry has to go, not just the api-type one the mirror would drop.
auth = m.load_json(m.OLD_AUTH_PATH)
auth['spectre'] = {'type': 'oauth', 'access': 'dead-oauth'}
m.save_json_atomic(m.OLD_AUTH_PATH, auth, mode=0o600)
m._write_env_mirror(m._load_cache())
assert 'SPECTRE_OAUTH_TOKEN=dead-oauth' in open(m.ZSENV_PATH).read()
# Pi keeps its own catalogue. Its model ids are bare and often vendor-prefixed --
# 'ghost/...' here is a vendor under a live provider, matching how the real file
# carries deepseek/... and meta/... under openrouter. Only the provider entry is
# ours to remove; matching a retired name against an id prefix would take a live
# provider's model with it.
m.save_json_atomic(m.PI_MODELS_PATH, {
    '_comment': 'left alone',
    'providers': {'ghost': {'base_url': 'http://ghost', 'models': [{'id': 'ghost-1'}]},
                  'demo': {'base_url': 'http://demo',
                           'models': [{'id': 'd1'}, {'id': 'ghost/borrowed-vendor-name'}]}},
})

# Drive the sweep the way refresh does -- off the registry, so the prune and the
# two read-back filters below all read one source rather than agreeing by luck.
_reg = m.load_json(m.REGISTRY_PATH)
_reg['retired_providers'] = ['ghost', 'spectre']
m.save_json(m.REGISTRY_PATH, _reg)
assert set(m._load_retired()) == {'ghost', 'spectre'}
# The sweep runs hourly and its report is the only visible sign it did anything,
# so it must name what it actually removed. 'absent' is retired but present
# nowhere, and must not be claimed.
_reg['retired_providers'] = ['ghost', 'spectre', 'absent', 'hermesonly']
m.save_json(m.REGISTRY_PATH, _reg)
# A provider left in Hermes and nowhere else: the only surface that can report it
# is the Hermes prune, so it proves that prune feeds the report rather than
# riding on a name some other surface already found.
import yaml as _yaml
_hcfg = _load_yaml(m.HERMES_CONFIG)
_hcfg['custom_providers'].append({'name': 'hermesonly', 'base_url': 'http://h', 'models': ['h1']})
with open(m.HERMES_CONFIG, 'w') as handle:
    _yaml.safe_dump(_hcfg, handle, sort_keys=False)
_report = io.StringIO()
with contextlib.redirect_stderr(_report):
    m._prune_retired(m._load_retired())
_said = {line.split(':')[0].strip() for line in _report.getvalue().splitlines() if 'retired' in line}
assert _said == {'ghost', 'spectre', 'hermesonly'}, _report.getvalue()

assert 'ghost' not in m._load_cache()
assert 'ghost' not in m.load_json(m.STATE_PATH)['providers']
assert 'ghost' not in m._load_capabilities()['providers']
opencode = m.load_json(m.OPENCODE_PATH)
assert 'ghost' not in opencode['provider']
assert opencode['disabled_providers'] == ['foreign-disabled']
assert 'GHOST_API_KEY' not in open(m.ZSENV_PATH).read()
assert 'ghost' not in m.load_json(m.OLD_AUTH_PATH)
assert 'spectre' not in m.load_json(m.OLD_AUTH_PATH)
assert 'SPECTRE_OAUTH_TOKEN' not in open(m.ZSENV_PATH).read()
_hnames = [e['name'] for e in _load_yaml(m.HERMES_CONFIG)['custom_providers']]
assert 'ghost' not in _hnames and 'hermesonly' not in _hnames, _hnames
pi = m.load_json(m.PI_MODELS_PATH)
assert 'ghost' not in pi['providers'], pi
assert 'demo' in pi['providers'] and pi['_comment'] == 'left alone', pi
# The live provider keeps every model, including the one whose vendor prefix
# happens to match the retired provider's name.
assert [e['id'] for e in pi['providers']['demo']['models']] == ['d1', 'ghost/borrowed-vendor-name'], pi
# Providers the registry still knows are untouched by the sweep.
assert 'demo' in m._load_cache()
assert 'foreign' in m.load_json(m.OPENCODE_PATH)['provider']
assert m.load_json(m.OLD_AUTH_PATH)['demo']['key'] == 'demo-key'

# Idempotent: the sweep runs on every hourly refresh, so a second pass on an
# already-clean machine must be a no-op rather than an error.
m._prune_retired(m._load_retired())
assert 'demo' in m._load_cache()

# The vault outlives the registry entry, so the folder pull -- which is keyed on
# vault item names, not registry names, on purpose -- must skip retired names.
# Without this the vault hands the key back the moment the sweep clears it. The
# stubs above list no ghost item, so they have to be replaced here or the loop
# never reaches the check and this passes on nothing.
m.vault_available = lambda: True
m.vault_list_items = lambda: [
    {'name': 'GHOST_API_KEY'},
    {'name': 'DEMO_API_KEY'},
]
m.vault_get = lambda name: {
    'GHOST_API_KEY': 'ghost-key-from-vault',
    'DEMO_API_KEY': 'demo-key',
}.get(name)
m.cache_set('ghost', 'ghost-key')
m._prune_retired(m._load_retired())
assert 'ghost' not in m._load_cache()
m._sync_cache_from_vault(servers)
assert 'ghost' not in m._load_cache(), 'the vault revived a retired provider'
# ... while a live provider in the same pull still refreshes normally, so the
# filter is not just switching the whole vault sync off.
assert m._load_cache()['demo'] == 'demo-key'
# ... and the .zshenv read-back, the other route into the cache.
with open(m.ZSENV_PATH, 'a') as handle:
    handle.write(f'\n{m.AUTH_BLOCK_BEGIN}\nexport GHOST_API_KEY=ghost-key\n{m.AUTH_BLOCK_END}\n')
m._sync_zsenv_to_cache(servers)
assert 'ghost' not in m._load_cache(), '.zshenv revived a retired provider'

# A name cannot be live and retired at once: the sweep would delete the
# credential the same refresh is about to write back.
try:
    m._validate_registry({'version': 1, 'providers': {'demo': {}}, 'retired_providers': ['demo']})
except ValueError as exc:
    assert 'both a provider and retired' in str(exc), exc
else:
    raise AssertionError('a live provider was accepted as retired')

# Nor the *credential* of a live provider. opencode-zen resolves through the
# enrollment filed under opencode-go, so retiring opencode-go would delete the
# key live zen needs -- and the two read-back filters then stop the vault from
# ever healing it. Silent and permanent, so it has to fail at validation.
_shared = {'version': 1, 'retired_providers': ['gone'], 'providers': {
    'borrower': {'provider_type': 'OpenAICompatible', 'base_url': 'http://borrower',
                 'api_format': 'openai', 'npm': '@ai-sdk/openai-compatible',
                 'auth': {'type': 'api-key', 'store': 'opencode', 'key': 'gone'},
                 'enabled': True}}}
try:
    m._validate_registry(_shared)
except ValueError as exc:
    assert 'credential of a live provider' in str(exc), exc
else:
    raise AssertionError('retiring a live provider\'s credential name was accepted')
# Retiring the borrower itself is fine -- nothing else resolves through it.
_shared['retired_providers'] = ['other']
m._validate_registry(_shared)
# And the real registry still validates, opencode-zen/opencode-go included.
m._validate_registry(m.load_json('$ROOT/files/provider-registry.json'))

# Naming convention: only {PROVIDER}_API_KEY items are conforming.
assert m._conforming_item_name('DEEPSEEK_API_KEY')
assert m._conforming_item_name('OPENCODE_GO_API_KEY')
assert not m._conforming_item_name('VAST.AI API KEY')
assert not m._conforming_item_name('GITHUB_COPILOT_OAUTH_TOKEN')
assert not m._conforming_item_name('deepseek_api_key')
PY

echo "providers tests passed"
