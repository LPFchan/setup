#!/usr/bin/env bash
# fleet owns the OpenCodex proxy once setup's own runtime is gone: the ocx
# config mirror, the idle-gated restart, Claude's route, and the hand-off guard.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" TEST_ROOT="$ROOT"
export FLEET_MANIFEST="$ROOT/files/fleet-manifest.json" FLEET_OCX_WAIT=0 FLEET_OCX_IDLE_WAIT=0
# Stand-ins for ocx and the service managers; nothing here may reach the real ones.
STUBS="$TMP/stubs" PACKAGE="$TMP/npm/lib/node_modules/@bitkyc08/opencodex"
mkdir -p "$HOME/.claude" "$STUBS" "$PACKAGE/bin" "$TMP/npm/bin"
printf '{"name":"@bitkyc08/opencodex","version":"2.0.0"}' > "$PACKAGE/package.json"
printf '#!/bin/sh\necho "$*" >> "%s/ocx.log"\n[ "$1" = --version ] && echo 2.0.0\nexit 0\n' "$TMP" > "$PACKAGE/bin/ocx"
for tool in systemctl launchctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/managers.log"\n' "$tool" "$TMP" > "$STUBS/$tool"
done
chmod +x "$PACKAGE/bin/ocx" "$STUBS"/*
# A pinned PATH: the real ocx in ~/.local/bin must stay out of reach.
export PATH="$STUBS:$TMP/npm/bin:/usr/bin:/bin" OCX_LINK="$TMP/npm/bin/ocx" OCX_LOG="$TMP/ocx.log" MANAGERS_LOG="$TMP/managers.log"
python3 - <<'PY'
import contextlib, copy, importlib.machinery, importlib.util, io, json, os, pathlib, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root=pathlib.Path(os.environ['TEST_ROOT']); home=pathlib.Path.home()
link=pathlib.Path(os.environ['OCX_LINK']); log=pathlib.Path(os.environ['OCX_LOG'])
def module(name,path):
    loader=importlib.machinery.SourceFileLoader(name,str(path))
    spec=importlib.util.spec_from_loader(name,loader)
    m=importlib.util.module_from_spec(spec);loader.exec_module(m);return m
def save(path,value):
    path=pathlib.Path(path);path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value))
def calls():
    out=log.read_text().splitlines() if log.exists() else [];log.unlink(missing_ok=True);return out
quiet=lambda:contextlib.redirect_stdout(io.StringIO())

# --- the ocx config mirror -------------------------------------------------
e=module('fleet_providers',root/'files/fleet-providers.py')
registry=json.loads((root/'files/provider-registry.json').read_text())
registry['providers']['gated']={'provider_type':'OpenAICompatible','base_url':'https://gated.invalid/v1',
    'api_format':'openai','npm':'@ai-sdk/openai-compatible','auth':{'type':'api-key','store':'opencode','key':'gated'},
    'enabled':True,'model_allow_ids':['big-pickle','union-alpha'],'model_no_reasoning_suffixes':['alpha']}
save(e.REGISTRY_PATH,registry)
save(e.STATE_PATH,{'version':1,'providers':{'commandcode':{'enabled':True},'zai':{'enabled':False},'deepseek':{'enabled':True}}})
def snapshot(name,models):
    base={'source_endpoint':f'https://{name}.test/v1/models','fetched_at':'2026-10-26T00:00:00Z','raw_response_sha256':'a'*64}
    return {'provider':name,'evidence_source':'provider_models_endpoint',**base,'models':{
        i:{'provider':name,'id':i,'metadata_fingerprint':'b'*64,**base,**r} for i,r in models.items()}}
save(e.CAPABILITIES_PATH,{'version':1,'providers':{'grimoire':snapshot('grimoire',{
    'qwen-big':{'context':393216,'reasoning':{'support':'full','supported_efforts':['low','high']}},
    'tiny':{'context':32768,'reasoning':{'support':'none'}}})}})
e._save_cache({'commandcode':'cc-key','grimoire':'gr-key','zai':'zai-key','gated':'gated-key','opencode-go':'go-key'})
config=pathlib.Path(e.OPENCODEX_CONFIG)
user={'port':10111,'myOwnKey':{'x':1},'providers':{
    'openai':{'adapter':'openai-responses','baseUrl':'https://chatgpt.com/backend-api/codex','authMode':'forward','mine':True},
    'user-added':{'adapter':'openai-chat','baseUrl':'https://u.test/v1'},
    'crofai':{'adapter':'openai-chat'},
    'anthropic':{'models':['claude-x'],'apiKey':'stale','defaultModel':'pinned'},
    'commandcode':{'models':['pinned'],'defaultModel':'x','custom':1},
    'cloudflare':{'modelReasoningEfforts':{'keep':['low']}}}}
save(config,user);save(e.OPENCODEX_MANAGED,{'version':1,'providers':['crofai','commandcode']})

# No fleet-owned ocx: OpenCodex is left alone.
e.OCX_BIN=None;e.sync_opencodex()
assert json.loads(config.read_text())==user and calls()==[]
os.symlink(pathlib.Path(os.environ['OCX_LINK']).parent.parent/'lib/node_modules/@bitkyc08/opencodex/bin/ocx',link)
e.OCX_BIN=str(link);e.sync_opencodex()
assert calls()==['sync']  # the Codex catalog is rebuilt from the new config
c=json.loads(config.read_text());p=c['providers']
# User-owned keys and providers survive; one the registry dropped goes.
assert c['myOwnKey']=={'x':1} and c['port']==10111 and p['openai']['mine'] and 'user-added' in p
assert 'crofai' not in p and 'grimoire' in json.loads(pathlib.Path(e.OPENCODEX_MANAGED).read_text())['providers']
assert c['hostname']=='127.0.0.1' and c['shutdownTimeoutMs']==300000
# Local enablement and the key both decide `disabled`.
assert p['commandcode']['disabled'] is False and p['zai']['disabled'] is True
assert p['deepseek']['disabled'] is True  # enabled, but no key
# An OAuth provider keeps OpenCodex's own `models`; an api-key pin and any default model go.
assert p['anthropic']=={'models':['claude-x'],'adapter':'anthropic','baseUrl':'https://api.anthropic.com','authMode':'oauth'}
assert 'models' not in p['commandcode'] and 'defaultModel' not in p['commandcode'] and p['commandcode']['custom']==1
# The capability cache narrows the catalog and carries ladders and context windows.
assert p['grimoire']['selectedModels']==['qwen-big','tiny']
assert p['grimoire']['modelReasoningEfforts']=={'qwen-big':['low','high']}
assert p['grimoire']['modelContextWindows']=={'qwen-big':393216,'tiny':32768}
assert p['cloudflare']['modelReasoningEfforts']=={'keep':['low']}  # absent from the cache: untouched
# Without a refreshed cache, an admission policy's registry list is the floor.
assert p['gated']['selectedModels']==['big-pickle','union-alpha'] and p['gated']['noReasoningModels']==['union-alpha']
# Nothing changed: nothing rewritten.
before=config.stat().st_mtime_ns;os.utime(config,ns=(1,1))
e.sync_opencodex();assert config.stat().st_mtime_ns==1;calls()
# An unreadable config is reported and left as it is.
config.write_text('{broken');err=io.StringIO()
with contextlib.redirect_stderr(err):e.sync_opencodex()
assert config.read_text()=='{broken' and 'OpenCodex config not written' in err.getvalue() and calls()==[]
save(config,c)

# Account teardown (logout, switch, 401): the proxy's config loses the old keys
# and, keyless, every API-key provider is disabled.
e.sync_opencodex();calls();managed=pathlib.Path(e.OPENCODEX_MANAGED)
assert json.loads(config.read_text())['providers']['commandcode']['apiKey']=='cc-key'
sha=json.loads(managed.read_text())['sha256']
e.bind_account(None)
torn=json.loads(config.read_text())['providers'];keyed=[p for p in torn.values() if p.get('authMode')=='key']
assert keyed and all(p['apiKey']=='' and p['disabled'] is True for p in keyed)
assert 'cc-key' not in config.read_text() and calls()==['sync']
assert json.loads(managed.read_text())['sha256']!=sha  # so the proxy gets restarted off them

# Hand-off: while setup's runtime is installed, its launcher owns the config.
launcher=pathlib.Path(e.OPENCODEX_BIN);launcher.parent.mkdir(parents=True,exist_ok=True)
launcher.write_text(f'#!/bin/sh\necho "launcher $*" >> "{log}"\n');launcher.chmod(0o755)
legacy=pathlib.Path(e.OPENCODEX_LEGACY);legacy.mkdir(parents=True)
config.unlink();e.sync_opencodex()
assert not config.exists() and calls()[0]=='launcher __apply --no-restart'

# --- the proxy -------------------------------------------------------------
proxy={'status':'ok','version':'2.0.0','turns':0}
class Proxy(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path=='/healthz':body={'status':proxy['status'],'version':proxy['version']}
        elif self.path=='/v1/models':body={'data':[{'id':'grimoire/qwen-big','reasoning_efforts':[
            {'value':'low','label':'Low Effort'},{'value':'high','label':'High','default':True}]}]}
        elif self.path=='/api/system/memory' and self.headers.get('Authorization')=='Bearer admin':
            body={'activeTurnCount':proxy['turns']}
        else:self.send_response(404);self.end_headers();return
        data=json.dumps(body).encode();self.send_response(200);self.send_header('Content-Length',str(len(data)))
        self.end_headers();self.wfile.write(data)
    def log_message(self,*a):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Proxy);threading.Thread(target=server.serve_forever,daemon=True).start()
port=server.server_address[1];url=f'http://127.0.0.1:{port}'
ocx_home=home/'.opencodex';started=ocx_home/'runtime-port.json'
save(started,{'port':port});(ocx_home/'admin-api-token').write_text('admin\n')
f=module('fleet_ocx',root/'files/fleet')
settings=home/'.claude/settings.json';zshenv=home/'.zshenv'
save(settings,{'model':'opus','env':{'OTHER':'1'}})
block='# BEGIN harnesses:anthropic-base-url\nexport ANTHROPIC_BASE_URL=http://127.0.0.1:1\n# END harnesses:anthropic-base-url\n'
zshenv.write_text('export KEEP=1\n\n'+block)
record=pathlib.Path(e.OPENCODEX_MANAGED)
def stale():  # the engine wrote a provider config the running proxy never loaded
    save(record,{**json.loads(record.read_text()),'sha256':os.urandom(8).hex()})

# Hand-off: fleet resolves no ocx, restarts nothing and leaves Claude's route alone.
stale()
assert f.ocx_bin() is None and f.provider_engine().OCX_BIN is None
with quiet():f.converge_ocx()
assert calls()==[] and json.loads(settings.read_text())=={'model':'opus','env':{'OTHER':'1'}}
with quiet(),contextlib.redirect_stderr(io.StringIO()):assert f.cmd_update(['ocx'])==1
assert calls()==[]  # nor does it update setup's copy
save(started,{'port':1});real_shell=f._shell;f._shell=lambda command:(_ for _ in ()).throw(AssertionError(command))
with quiet():assert f.cmd_install(['ocx'])==0  # nor reinstall over it, even with nothing serving
f._shell=real_shell;save(started,{'port':port})
legacy.rmdir()
assert f.ocx_bin()==str(link) and f.provider_engine().OCX_BIN==str(link)

# T3 reads the proxy's address itself.
assert f.proxy_url()==url
assert f._effort_descriptors()['grimoire/qwen-big']['options']==[{'id':'low','label':'Low'},{'id':'high','label':'High','isDefault':True}]

# A provider config the proxy has not loaded waits for no turn in flight.
proxy['turns']=1;err=io.StringIO()
with quiet(),contextlib.redirect_stderr(err):f.converge_ocx()
assert 'service restart' not in calls() and 'put off to the next night' in err.getvalue()
proxy['turns']=0
with quiet():f.converge_ocx()
assert calls()==['service restart']
# Current proxy: no restart, however recently ocx rewrote its own config.
save(config,{'ocxOwned':1})  # ocx rewrites config.json itself
with quiet():f.converge_ocx()
assert calls()==[]
# A newer build on disk: restart.
proxy['version']='1.9.0'
with quiet():f.converge_ocx()
assert calls()==['service restart'];proxy['version']='2.0.0'
# restart_required already refuses every request, so it does not wait.
proxy['status']='restart_required';proxy['turns']=1
with quiet():f.converge_ocx()
assert calls()==['service restart'];proxy.update(status='ok',turns=0)

# `fleet install ocx` leaves the config written and the proxy serving it.
target=os.readlink(link);link.unlink();config.unlink()
dropin=home/'.config/systemd/user/opencodex-proxy.service.d/50-stop-timeout.conf';dropin.unlink(missing_ok=True)
f._shell=lambda command:['ln','-s',target,str(link)]
with quiet():assert f.cmd_install(['ocx'])==0
assert calls()==['sync','service restart'] and 'grimoire' in json.loads(config.read_text())['providers']
# The next sync and nightly with nothing changed restart nothing, though ocx rewrote its config.
f.provider_engine().sync_opencodex();calls()
save(config,{**json.loads(config.read_text()),'ocxOwned':2})
with quiet():f.converge_ocx()
assert calls()==[]
# systemd gets the stop timeout the proxy's 300s drain needs, once.
assert dropin.read_text()=='[Service]\nTimeoutStopSec=330\n'
reloads=lambda:pathlib.Path(os.environ['MANAGERS_LOG']).read_text().count('systemctl --user daemon-reload')
before=reloads();f._ocx_stop_timeout();assert reloads()==before>0
ran=[];f._shell=lambda command:ran.append(command) or ['true']
with quiet():assert f.cmd_install(['ocx'])==0  # installed and serving: nothing runs
assert calls()==[] and ran==[]
# Installed but not serving (the service never came up): install runs again to repair it.
save(started,{'port':1})
with quiet(),contextlib.redirect_stderr(io.StringIO()):assert f.cmd_install(['ocx'])==1
assert len(ran)==1 and 'ocx' in ran[0];save(started,{'port':port})

# On Windows `ocx update` stops and restarts the proxy, so it runs only for a
# new release, and only while no turn is in flight.
f.WINDOWS=True;err=io.StringIO()
for latest in (None,'2.0.0'):  # lookup failed, or already on it
    f._npm_latest=lambda package,v=latest:v
    with quiet(),contextlib.redirect_stderr(err):assert f.cmd_update(['ocx'])==0
    assert calls()==[]
f._npm_latest=lambda package:'2.1.0';proxy['turns']=1
with quiet(),contextlib.redirect_stderr(err):assert f.cmd_update(['ocx'])==0
assert calls()==[] and 'update is put off' in err.getvalue()
proxy['turns']=0
with quiet():assert f.cmd_update(['ocx'])==0
assert 'update' in calls();f.WINDOWS=False

# Claude's route lives in its settings; setup's .zshenv block and service exports go.
r=json.loads(settings.read_text())
assert r=={'model':'opus','env':{'OTHER':'1','ANTHROPIC_BASE_URL':url}},r
assert zshenv.read_text()=='export KEEP=1\n\n'
managers=pathlib.Path(os.environ['MANAGERS_LOG']).read_text()
assert 'systemctl --user unset-environment ANTHROPIC_BASE_URL' in managers
# A plain sync rewrites config and the route but never restarts the proxy.
stale()
for n in ('_fleet_lock','sync_ssh','sync_agents','sync_builtin_skill','sync_links','render_harnesses','sync_provider_credentials','_remove_hourly_providers'):
    setattr(f,n,{'_fleet_lock':contextlib.nullcontext,'sync_ssh':lambda c:0,'sync_agents':lambda push:0,
                 'render_harnesses':lambda:True,'_remove_hourly_providers':lambda:False}.get(n,lambda *a,**k:None))
real_engine=f.provider_engine;f.provider_engine=lambda:None
with quiet():assert f.cmd_sync(pull=True)==0
assert calls()==[]
# An account change found by a sync (a logout here) restarts the proxy off the
# old keys once it is idle, instead of at the nightly pass; an unchanged one does not.
converged=[];real_converge=f.converge_ocx;f.converge_ocx=lambda:converged.append(1)
f.provider_engine=real_engine;f._auth=lambda *args:(4,'')
real_engine()._save_cache({'_fleet_account':{'origin':'https://auth.test','subject':'1'},'commandcode':'cc-key'})
with quiet():f.cmd_sync(pull=True)
assert converged==[1] and 'cc-key' not in config.read_text();calls()
with quiet():f.cmd_sync(pull=True)
assert converged==[1];f.converge_ocx=real_converge;calls()
# A proxy that stays down loses the route; other env entries stay. Something
# else on its port answering garbage reads as no proxy, not a crash.
server.shutdown();server.server_close()
import socketserver
class Garbage(socketserver.BaseRequestHandler):
    def handle(self):self.request.recv(1024);self.request.sendall(b'GET /v1/models HTTP/1.1\r\n\r\n')
other=socketserver.ThreadingTCPServer(('127.0.0.1',0),Garbage);threading.Thread(target=other.serve_forever,daemon=True).start()
save(started,{'port':other.server_address[1]-1})  # probed first, as the token-less port
assert f.proxy_url() is None and f._ocx_live()==(None,None)
save(started,{'port':other.server_address[1]})
assert f.proxy_url() is None and f._ocx_live()==(None,None) and f._effort_descriptors()=={}
with quiet():f.route_claude()
assert json.loads(settings.read_text())=={'model':'opus','env':{'OTHER':'1'}}
other.shutdown();other.server_close()

# Nightly, fleet-owned: refresh, harness updates, then the restart and route.
order=[]
f.cmd_sync=lambda **kw:order.append('sync') or 0
f.provider_engine=lambda:object()
f.refresh_provider_models=lambda:order.append('models') or 0
f.cmd_update=lambda names:order.append('harnesses') or 0
f.converge_ocx=lambda:order.append('converge')
f._self_update=lambda:order.append('self-update')
launcher.write_text('')  # setup's slim launcher may stay: without its runtime it applies nothing
assert f.cmd_nightly()==0 and order==['self-update','sync','models','harnesses','converge'] and calls()==[]
print('fleet ocx mirror, restart, route and hand-off tests passed')
PY

# --- where npm puts the package ----------------------------------------------
# A writable global folder (nvm, Homebrew) is used as it is. A system Node's
# needs root, so the package goes into its own prefix and only `ocx` is linked
# into ~/.local/bin, where `opencodex` is setup's picker. Install and update
# stay with a package already in that prefix.
NPM="$TMP/npmstub" OWN="$HOME/.local/share/opencodex"
mkdir -p "$NPM/bin" "$NPM/system/lib" "$NPM/global/lib" "$NPM/global/bin" "$HOME/.local/bin"
chmod a-w "$NPM/system/lib"
# Like npm: unpack, link both names, and refuse to replace an existing file.
cat > "$NPM/bin/npm" <<STUB
#!/bin/sh
[ "\$1 \$2" = "prefix -g" ] && { cat "$NPM/prefix"; exit 0; }
echo "npm \$*" >> "$NPM/calls"
prefix=; while [ \$# -gt 0 ]; do [ "\$1" = --prefix ] && prefix=\$2; shift; done
pkg="\$prefix/lib/node_modules/@bitkyc08/opencodex"
for name in ocx opencodex; do
    [ -e "\$prefix/bin/\$name" ] && [ ! -L "\$prefix/bin/\$name" ] && { echo "EEXIST \$prefix/bin/\$name" >&2; exit 1; }
done
mkdir -p "\$pkg/bin" "\$prefix/bin"
printf '#!/bin/sh\necho "ocx \$*" >> "$NPM/calls"\n' > "\$pkg/bin/ocx.mjs"
chmod +x "\$pkg/bin/ocx.mjs"
for name in ocx opencodex; do ln -sf "\$pkg/bin/ocx.mjs" "\$prefix/bin/\$name"; done
STUB
chmod +x "$NPM/bin/npm"
printf '#!/bin/sh\n# setup picker\n' > "$HOME/.local/bin/opencodex"
ocx_run() {  # kind, npm's global prefix -> what npm and ocx were asked to do
    python3 -c 'import json, sys
specs = {h["name"]: h for h in json.load(open(sys.argv[1]))["harnesses"]}
print(specs["ocx"][sys.argv[2]])' "$ROOT/files/fleet-manifest.json" "$1" > "$NPM/command"
    echo "$2" > "$NPM/prefix"; : > "$NPM/calls"
    PATH="$NPM/bin:/usr/bin:/bin" bash -o pipefail -c "$(cat "$NPM/command")"
    cat "$NPM/calls"
}
expect() { [[ "$2" == "$3" ]] || { echo "FAIL: $1: $2" >&2; exit 1; }; }
package="--allow-scripts=bun @bitkyc08/opencodex"
expect "install, writable global prefix" "$(ocx_run install "$NPM/global")" \
    "npm install -g --prefix $NPM/global $package"$'\n'"ocx service"
expect "update, writable global prefix" "$(ocx_run update "$NPM/global")" \
    "npm install -g --prefix $NPM/global $package@latest"
[[ ! -e "$HOME/.local/bin/ocx" ]] || { echo "FAIL: linked ocx for a global install" >&2; exit 1; }
if [ "$(id -u)" != 0 ]; then  # root can write anywhere
    expect "install, system prefix" "$(ocx_run install "$NPM/system")" \
        "npm install -g --prefix $OWN $package"$'\n'"ocx service"
    [[ "$(readlink "$HOME/.local/bin/ocx")" == "$OWN/bin/ocx" ]] || { echo "FAIL: ~/.local/bin/ocx" >&2; exit 1; }
else
    mkdir -p "$OWN/lib/node_modules/@bitkyc08/opencodex"
fi
grep -q 'setup picker' "$HOME/.local/bin/opencodex" || { echo "FAIL: the picker was replaced" >&2; exit 1; }
expect "update, package in its own prefix" "$(ocx_run update "$NPM/global")" \
    "npm install -g --prefix $OWN $package@latest"
expect "install (repair), package in its own prefix" "$(ocx_run install "$NPM/global")" \
    "npm install -g --prefix $OWN $package"$'\n'"ocx service"
chmod u+w "$NPM/system/lib"
echo "fleet ocx npm prefix tests passed"
