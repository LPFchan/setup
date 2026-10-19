#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" TEST_ROOT="$ROOT"
mkdir -p "$HOME"
python3 - <<'PY'
import base64, copy, hashlib, importlib.machinery, importlib.util, json, os, pathlib, sys
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
m._save_cache({'_common_auth_context':ctx})
imported=m.legacy_settings(ctx)
assert not imported['enabled']['demo'] and not target.exists()
assert legacy.exists()
assert json.loads((home/'.local/state/fleet/backup/provider-registry.json').read_text())==registry
assert json.loads((home/'.local/state/fleet/backup/provider-state.json').read_text())['providers']['demo']['enabled'] is False
save(target,imported)
assert m.legacy_settings(ctx) is None
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
# Fleet manages its own two schedules; setup owns legacy retirement.
f=module('fleet_test',root/'files/fleet');calls=[]
f.provider_engine=lambda:object();f._run_schedule=lambda *args,**kw:calls.append(args) or 0
f.sys.argv=[str(root/'files/fleet')]
assert f.schedule_enable()==0
assert not any(c[:3]==('uninstall-timer','user','providers') for c in calls)
assert any(c[:3]==('install-timer','user','fleet-providers') and '__refresh-providers' in c[4] for c in calls)
assert any(c[:3]==('install-timer','user','fleet-sync') for c in calls)
calls.clear();assert f.schedule_disable()==0
assert any(c[:3]==('uninstall-timer','user','fleet-providers') for c in calls)
assert any(c[:3]==('uninstall-timer','user','fleet-sync') for c in calls)
# Failed Linux and macOS schedule installation cannot retire the working legacy job.
from unittest.mock import patch
from types import SimpleNamespace
calls.clear()
with patch.object(f,'_run_schedule',side_effect=lambda *args,**kw:calls.append(args) or 1):
    assert f.provider_schedule(True)==1
assert not any(c[:3]==('uninstall-timer','user','providers') for c in calls)
legacy_plist=f.LAUNCHD_DIR/'com.lost.plus.providers.plist'
legacy_plist.parent.mkdir(parents=True,exist_ok=True);legacy_plist.write_text('legacy')
calls.clear()
with patch.object(sys,'platform','darwin'), patch.object(f.subprocess,'run',side_effect=lambda args,**kw:calls.append(args) or SimpleNamespace(returncode=1)):
    assert f.provider_schedule(True)==1
assert legacy_plist.read_text()=='legacy'
assert not any('com.lost.plus.providers' in arg for call in calls for arg in call)
# The timer pulls the account before refreshing; operator CLI management is absent.
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
save(n.SETTINGS_PATH,n.legacy_settings(ctx))
n.sync_credentials(ctx,lambda:copy.deepcopy(catalog))
assert n._provider_settings()['enabled']['demo'] is True
for label,new_context in [('other-subject',other),('other-origin',{'origin':'https://other.test','subject':ctx['subject']})]:
    n=isolated_engine(label);n.context=new_context
    save(n.REGISTRY_PATH,registry);save(n.STATE_PATH,{'version':1,'providers':{'demo':{'enabled':True}}})
    n._save_cache({'demo':'old-account-key','_common_auth_context':ctx,'_fleet_account':ctx})
    assert n.legacy_settings(new_context) is None
    for _ in range(2):
        n.sync_credentials(new_context,lambda:copy.deepcopy(catalog))
        assert not pathlib.Path(n.SETTINGS_PATH).exists()
        assert not n._load_provider_state()['providers']['demo']['enabled']
        assert not n.cache_get('demo')
# Migration publishes just the enabled map before the normal pull records it.
# Failed pushes leave no local import, while a concurrent dashboard save wins.
for scenario in ('retry','stale'):
    n=isolated_engine('upload-'+scenario);n.context=ctx
    save(n.REGISTRY_PATH,registry);save(n.STATE_PATH,{'version':1,'providers':{'demo':{'enabled':True}}})
    n._save_cache({'_common_auth_context':ctx})
    fleet=module('fleet_migration_'+scenario,root/'files/fleet')
    fleet.AGENTS=pathlib.Path(n.SETTINGS_PATH).parent/'agents'
    fleet.PROVIDER_SETTINGS=fleet.AGENTS/'settings/providers.json'
    n.SETTINGS_PATH=str(fleet.PROVIDER_SETTINGS)
    fleet.FLEET_STATE=pathlib.Path(n.SETTINGS_PATH).parents[2]/'fleet-state'
    fleet.AGENTS_STATE=fleet.FLEET_STATE/'agents.json'
    fleet.provider_engine=lambda:n
    fleet._subject=lambda:ctx['subject']
    save(fleet.AGENTS/'settings/local-only.json',{'local':'keep private'})
    remote={};counter=0;attempts=[];fail=True
    def metadata(path):
        return {'path':path,'sha256':hashlib.sha256(base64.b64decode(remote[path]['content'])).hexdigest(),
                'executable':False}
    def api(method,path,body=None):
        global counter,fail
        if path=='/api/fleet/config':
            return {'counter':counter,'files':[metadata(p) for p in remote],'installs':[]}
        if path=='/api/fleet/config/push':
            attempts.append(copy.deepcopy(body))
            assert body['subject']==ctx['subject'] and body['base']==counter
            assert body['delete']==[] and [p['path'] for p in body['put']]==['settings/providers.json']
            if fail:
                fail=False
                if scenario=='stale':
                    remote['settings/providers.json']={'content':base64.b64encode(json.dumps({'version':2,'enabled':{'demo':False}}).encode()).decode()}
                    counter+=1
                    raise fleet.ApiError('stale',409)
                raise fleet.ApiError('offline')
            remote.update({p['path']:{'content':p['content']} for p in body['put']});counter+=1
            return {'counter':counter}
        if path=='/api/fleet/config/fetch':
            return {'files':[{**metadata(p),**remote[p]} for p in body['paths']]}
        raise AssertionError((method,path))
    fleet._api=api
    if scenario=='retry':
        try:fleet.sync_agents(push=False)
        except fleet.ApiError:pass
        else:raise AssertionError('offline import succeeded')
        assert not fleet.PROVIDER_SETTINGS.exists() and not pathlib.Path(n.CATALOG_PATH).exists()
    fleet.sync_agents(push=False)
    expected=scenario=='retry'
    assert json.loads(base64.b64decode(remote['settings/providers.json']['content']))['enabled']['demo'] is expected
    assert json.loads(fleet.PROVIDER_SETTINGS.read_text())['enabled']['demo'] is expected
    assert 'settings/local-only.json' not in remote
    assert json.loads(fleet.AGENTS_STATE.read_text())['files']['settings/providers.json']==hashlib.sha256(fleet.PROVIDER_SETTINGS.read_bytes()).hexdigest()
    count=len(attempts);fleet.sync_agents(push=False)
    assert len(attempts)==count
    if scenario=='retry':
        assert (fleet.AGENTS/'settings/local-only.json').exists()
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
    if (root/'migration-schedule-fail').exists():
        sys.exit(1)
    (root/'migration-new-schedule').touch()
if sys.argv[1:] == ['schedule', 'status']:
    print('fleet: nightly pass ' + ('on' if (root/'migration-schedule-active').exists() else 'off'))
PY
cat > "$HOME/.local/bin/providers" <<'SH'
#!/bin/sh
[ -f "$HOME/migration-new-schedule" ] || exit 1
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
[[ -x "$HOME/.local/bin/providers" && ! -e "$HOME/migration-legacy-schedule" ]]
# Only a settings hash acknowledged by Auth permits retirement.
python3 - <<'PY'
import hashlib,json,os,pathlib
home=pathlib.Path.home();state=pathlib.Path(os.environ['XDG_STATE_HOME'])/'fleet/agents.json'
value=json.loads(state.read_text())
value['files']={'settings/providers.json':hashlib.sha256((home/'.agents/settings/providers.json').read_bytes()).hexdigest()}
state.write_text(json.dumps(value))
PY
touch "$HOME/migration-schedule-fail"
if _apply updated >/dev/null; then echo 'failed scheduler was accepted' >&2; exit 1; fi
[[ -x "$HOME/.local/bin/providers" && ! -e "$HOME/migration-legacy-schedule" ]]
rm "$HOME/migration-schedule-fail"
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
