#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" TEST_ROOT="$ROOT"
mkdir -p "$HOME"
python3 - <<'PY'
import copy, importlib.machinery, importlib.util, json, os, pathlib, sys
root=pathlib.Path(os.environ['TEST_ROOT']); home=pathlib.Path.home()
def module(name,path):
    loader=importlib.machinery.SourceFileLoader(name,str(path))
    spec=importlib.util.spec_from_loader(name,loader)
    m=importlib.util.module_from_spec(spec);loader.exec_module(m);return m
m=module('fleet_providers',root/'files/fleet-providers.py')
read_items=m.vault_list_items
def save(path,value):
    pathlib.Path(path).parent.mkdir(parents=True,exist_ok=True);pathlib.Path(path).write_text(json.dumps(value))
ctx={'origin':'https://auth.test','subject':'1'}
legacy=home/'.config/providers/registry.json'; target=home/'.agents/settings/providers.json'
registry={'version':1,'providers':{'demo':{'provider_type':'OpenAICompatible','base_url':'https://example.test/v1','api_format':'openai','npm':'@ai-sdk/openai-compatible','auth':{'type':'api-key','store':'opencode','key':'demo'},'enabled':True}}}
save(legacy,registry);save(m.STATE_PATH,{'version':1,'providers':{'demo':{'enabled':False}}})
m.bootstrap(str(target),str(root/'files/provider-registry.json'),import_legacy=True)
assert not json.loads(target.read_text())['enabled']['demo']
assert legacy.exists()
assert json.loads((home/'.local/state/fleet/backup/provider-registry.json').read_text())==registry
m.bootstrap(str(target),str(root/'files/provider-registry.json'))
assert not json.loads(target.read_text())['enabled']['demo']
new=home/'new-account/providers.json';m.bootstrap(str(new),str(root/'files/provider-registry.json'))
assert json.loads(new.read_text())=={'version':2,'enabled':{}}
m.SETTINGS_PATH=str(target)
m.DEFAULTS_PATH=str(root/'files/provider-registry.json')
m.REGISTRY_PATH=str(home/'.config/providers/registry.json')
shared={'version':1,'registry':copy.deepcopy(registry)}
m.materialize_catalog(ctx,shared)
effective=json.loads(pathlib.Path(m.REGISTRY_PATH).read_text())
assert not effective['providers']['demo']['enabled']
assert {'codex','anthropic'} <= set(effective['providers'])
# Shared URLs win; account files have no descriptor fields.
shared['registry']['providers']['demo']['base_url']='https://updated.test/v1'
m.materialize_catalog(ctx,shared)
assert json.loads(pathlib.Path(m.REGISTRY_PATH).read_text())['providers']['demo']['base_url']=='https://updated.test/v1'
assert 'base_url' not in target.read_text()
try:m._add_provider('unregistered','https://example.test/v1','private-key')
except ValueError as exc:assert 'administrator' in str(exc)
else:raise AssertionError('CLI enrolled a provider outside the shared catalog')
# A malformed account file cannot smuggle routing or keys into fleet.
save(target,registry)
try:m.materialize_catalog(ctx,shared)
except ValueError:pass
else:raise AssertionError('account descriptor accepted')
save(target,{'version':2,'enabled':{'demo':False}})
# Removed shared providers stay retired in the effective registry.
m.materialize_catalog(ctx,{'version':2,'registry':{'version':1,'providers':{},'retired_providers':['demo']}})
assert m._load_retired()==['demo']
# Catalog outage uses only a cache bound to the current account.
save(m.CATALOG_PATH,{'account':ctx,'catalog':shared})
m.common_auth_context=lambda:ctx
m._sync_common_auth=lambda servers:None
m._sync_cache_from_vault=lambda servers:None
m._sync_opencodex_provider_statuses=lambda **kw:None
m.sync_credentials(ctx,lambda:(_ for _ in ()).throw(OSError('offline')))
assert 'demo' in json.loads(pathlib.Path(m.REGISTRY_PATH).read_text())['providers']
other={'origin':'https://auth.test','subject':'2'}
m.common_auth_context=lambda:other
try:m.sync_credentials(other,lambda:(_ for _ in ()).throw(OSError('offline')))
except OSError:pass
else:raise AssertionError('another account used cached provider catalog')
# An explicit session rejection revokes cached keys rather than using offline state.
m.common_auth_context=lambda:ctx
m._save_cache({'demo':'rejected-account-key','_fleet_account':ctx})
class Rejected(Exception):status=401
try:m.sync_credentials(ctx,lambda:(_ for _ in ()).throw(Rejected('revoked')))
except Rejected:pass
else:raise AssertionError('rejected setup session used cached catalog')
assert not m.cache_get('demo')
# Restore the real vault reconciliation seam for the credential tests.
m=module('fleet_providers_keys',root/'files/fleet-providers.py');read_items=m.vault_list_items
# Legacy keys migrate only under their original account binding.
m._save_cache({'demo':'account-one-key','_common_auth_context':ctx})
m.bind_account(ctx)
assert m.cache_get('demo')=='account-one-key'
m._sync_mirrors();m._sync_opencodex_provider_statuses=lambda **kw:None
m.bind_account({'origin':'https://auth.test','subject':'2'})
assert not m.cache_get('demo')
assert 'account-one-key' not in pathlib.Path(m.OLD_AUTH_PATH).read_text()
assert 'account-one-key' not in pathlib.Path(m.ZSENV_PATH).read_text()
assert m._get_key('demo')==''
os.environ['DEMO_API_KEY']='old-shell-key'
assert m._get_key('demo')==''
# A successful list is authoritative; an outage keeps the last good copy.
m._save_cache({'demo':'current-key','_fleet_account':ctx})
m.VAULT_TOKEN='test';m.vault_list_items=lambda:[]
m._sync_cache_from_vault({})
assert not m.cache_get('demo')
m.cache_set('demo','current-key')
m.vault_list_items=lambda:(_ for _ in ()).throw(m.VaultError('offline'))
m._sync_cache_from_vault({})
assert m.cache_get('demo')=='current-key'
# The current Passage list shape is a list of folder groups.
m._vault_call=lambda *args:json.dumps([{'folder':'llm','items':[{'name':'DEMO_API_KEY'}]}])
assert read_items()==[{'name':'DEMO_API_KEY'}]
# Both schedules belong to fleet, including teardown of the retired timer.
f=module('fleet_test',root/'files/fleet');calls=[]
f.provider_engine=lambda:object();f._run_schedule=lambda *args,**kw:calls.append(args) or 0
f.sys.argv=[str(root/'files/fleet')]
assert f.schedule_enable()==0
assert any(c[:3]==('uninstall-timer','user','providers') for c in calls)
assert any(c[:3]==('install-timer','user','fleet-providers') and 'providers refresh' in c[4] for c in calls)
assert any(c[:3]==('install-timer','user','fleet-sync') for c in calls)
calls.clear();assert f.schedule_disable()==0
assert any(c[:3]==('uninstall-timer','user','fleet-providers') for c in calls)
assert any(c[:3]==('uninstall-timer','user','fleet-sync') for c in calls)
print('fleet provider migration, account isolation, vault and schedule tests passed')
PY
