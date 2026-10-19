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
assert json.loads((home/'.local/state/fleet/backup/provider-state.json').read_text())['providers']['demo']['enabled'] is False
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
assert any(c[:3]==('install-timer','user','fleet-providers') and '__refresh-providers' in c[4] for c in calls)
assert any(c[:3]==('install-timer','user','fleet-sync') for c in calls)
calls.clear();assert f.schedule_disable()==0
assert any(c[:3]==('uninstall-timer','user','fleet-providers') for c in calls)
assert any(c[:3]==('uninstall-timer','user','fleet-sync') for c in calls)
# The timer pulls the account before refreshing; operator CLI management is absent.
from types import SimpleNamespace
calls.clear()
engine=SimpleNamespace(common_auth_context=lambda:ctx,
    refresh_models=lambda:calls.append('models'), CommonAuthContextChanged=m.CommonAuthContextChanged,
    VaultError=m.VaultError, CommonAuthError=m.CommonAuthError, bind_account=lambda _:None)
f.provider_engine=lambda:engine
f.cmd_sync=lambda **kw:calls.append(('sync',kw)) or 0
f._auth=lambda *args:(0,json.dumps(ctx))
f._heal_path=lambda:None
f.sys.argv=[str(root/'files/fleet'),'__refresh-providers']
assert f.main()==0 and calls==[('sync',{'pull':True}),'models']
import contextlib,io
for args in (['providers'],['providers','add'],['providers','capabilities']):
    f.sys.argv=[str(root/'files/fleet'),*args]
    with contextlib.redirect_stderr(io.StringIO()):assert f.main()==2
assert 'fleet providers' not in f.USAGE

# Pull-only first syncs reconcile catalog/credentials without a settings file.
# Legacy choices require the registry's original origin and subject, and an
# Auth-derived registry must never be re-imported as legacy on the next sync.
def isolated_engine(label):
    n=module('provider_first_sync_'+label,root/'files/fleet-providers.py')
    folder=home/label
    for attr,filename in [('SETTINGS_PATH','settings.json'),('REGISTRY_PATH','registry.json'),
                          ('STATE_PATH','state.json'),('CACHE_PATH','credentials.json'),
                          ('CATALOG_PATH','catalog.json'),('CAPABILITIES_PATH','capabilities.json')]:
        setattr(n,attr,str(folder/filename))
    n.DEFAULTS_PATH=str(root/'files/provider-registry.json')
    n.common_auth_context=lambda:n.context
    def common(_):
        cache=n._load_cache();cache['_common_auth_context']=n.context;n._save_cache(cache)
    n._sync_common_auth=common
    n._sync_cache_from_vault=lambda _:None
    n._sync_mirrors=lambda **kw:None
    n._prune_retired=lambda _:None
    n._sync_opencode_provider_statuses=lambda _:None
    n._sync_hermes_mirror=lambda *args,**kw:None
    n._sync_pi_models_mirror=lambda *args:None
    n._sync_opencodex_provider_statuses=lambda **kw:None
    return n
catalog=copy.deepcopy(shared);catalog['registry']['providers']['demo']['enabled']=False
n=isolated_engine('fresh');n.context=ctx
for _ in range(2):
    n.sync_credentials(ctx,lambda:copy.deepcopy(catalog))
    assert pathlib.Path(n.REGISTRY_PATH).exists()
    assert not pathlib.Path(n.SETTINGS_PATH).exists()
    assert not n._load_provider_state()['providers']['demo']['enabled']
n=isolated_engine('legacy');n.context=ctx
save(n.REGISTRY_PATH,registry);save(n.STATE_PATH,{'version':1,'providers':{'demo':{'enabled':True}}})
n._save_cache({'demo':'own-key','_common_auth_context':ctx})
n.sync_credentials(ctx,lambda:copy.deepcopy(catalog))
assert n._provider_settings()['enabled']['demo'] is True
for label,new_context in [('other-subject',other),('other-origin',{'origin':'https://other.test','subject':ctx['subject']})]:
    n=isolated_engine(label);n.context=new_context
    save(n.REGISTRY_PATH,registry);save(n.STATE_PATH,{'version':1,'providers':{'demo':{'enabled':True}}})
    n._save_cache({'demo':'old-account-key','_common_auth_context':ctx,'_fleet_account':ctx})
    for _ in range(2):
        n.sync_credentials(new_context,lambda:copy.deepcopy(catalog))
        assert not pathlib.Path(n.SETTINGS_PATH).exists()
        assert not n._load_provider_state()['providers']['demo']['enabled']
        assert not n.cache_get('demo')
print('fleet provider migration, account isolation, vault and schedule tests passed')
PY

zsh <<'ZSH'
set -euo pipefail
source "$TEST_ROOT/lib/script-helpers.sh"
FLEET_BIN="$HOME/.local/bin/fleet"
FLEET_MANIFEST="$HOME/.config/fleet/manifest.json"
FLEET_PROVIDER_ENGINE="$HOME/.local/bin/fleet-providers.py"
FLEET_PROVIDER_DEFAULTS="$HOME/.config/fleet/provider-defaults.json"
FLEET_SOURCE="$HOME/migration-fleet.py"
FLEET_MANIFEST_SOURCE="$TEST_ROOT/files/fleet-manifest.json"
FLEET_PROVIDER_SOURCE="$TEST_ROOT/files/fleet-providers.py"
PROVIDER_REGISTRY_SOURCE="$TEST_ROOT/files/provider-registry.json"
source "$TEST_ROOT/files/fleet.sh"
_login_if_needed() { :; }
mkdir -p "$HOME/.local/bin" "$HOME/.agents/settings" "$HOME/.config/providers" "$XDG_STATE_HOME/fleet"
cat > "$FLEET_SOURCE" <<'PY'
#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path.home()
if sys.argv[1:2] == ['sync']:
    sys.exit(int((root/'migration-sync-status').read_text()))
if sys.argv[1:] == ['schedule', 'enable']:
    (root/'migration-new-schedule').touch()
if sys.argv[1:] == ['schedule', 'status']:
    print('fleet: nightly pass ' + ('on' if (root/'migration-schedule-active').exists() else 'off'))
PY
cat > "$HOME/.local/bin/providers" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/migration-legacy-schedule"
SH
chmod +x "$HOME/.local/bin/providers"
rm -f "$HOME/.agents/settings/providers.json" "$XDG_STATE_HOME/fleet/agents.json" "$HOME/.config/providers/catalog.json"
printf '3' > "$HOME/migration-sync-status"
_apply updated >/dev/null
[[ -x "$HOME/.local/bin/providers" && ! -e "$HOME/migration-legacy-schedule" ]]
[[ "$(status)" == *unknown* ]]
# An online sync without migrated settings also preserves the working command.
printf '0' > "$HOME/migration-sync-status"
_apply updated >/dev/null
[[ -x "$HOME/.local/bin/providers" && ! -e "$HOME/migration-legacy-schedule" ]]
if status >/dev/null; then echo 'migration was reported current too early' >&2; exit 1; fi
printf '%s\n' '{"subject":"account-a"}' > "$XDG_STATE_HOME/fleet/agents.json"
printf '%s\n' '{"version":2,"enabled":{"demo":false}}' > "$HOME/.agents/settings/providers.json"
printf '%s\n' '{"account":{"subject":"account-b"}}' > "$HOME/.config/providers/catalog.json"
_apply updated >/dev/null
[[ -x "$HOME/.local/bin/providers" && ! -e "$HOME/migration-legacy-schedule" ]]
printf '%s\n' '{"account":{"subject":"account-a"}}' > "$HOME/.config/providers/catalog.json"
_apply updated >/dev/null
[[ ! -e "$HOME/.local/bin/providers" && -e "$HOME/migration-new-schedule" ]]
[[ "$(cat "$HOME/migration-legacy-schedule")" == 'schedule disable' ]]
[[ "$(status)" == *current* ]]
echo 'offline and account-bound provider retirement tests passed'
# Existing Unix fleet schedules acquire the hourly timer even without a legacy module.
rm "$HOME/migration-new-schedule"
touch "$HOME/migration-schedule-active"
_apply updated >/dev/null
[[ -e "$HOME/migration-new-schedule" ]]
# Updating fleet preserves a deliberately disabled schedule.
rm "$HOME/migration-new-schedule" "$HOME/migration-schedule-active"
_apply updated >/dev/null
[[ ! -e "$HOME/migration-new-schedule" ]]
echo 'Unix fleet schedule upgrade and opt-out tests passed'
ZSH
