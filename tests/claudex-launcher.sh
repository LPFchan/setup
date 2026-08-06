#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home"
export CLAUDEX_CORE="$TEST_TMP/core"
export CLAUDEX_CONFIG="$HOME/.config/claudex/config.toml"
export CLAUDEX_REGISTRY="$ROOT/files/provider-registry.json"
export CLAUDEX_AUTH_JSON="$HOME/.local/share/opencode/auth.json"
export CLAUDEX_SESSIONS="$HOME/.config/claudex/sessions.tsv"
export TEST_TMP
mkdir -p "$HOME/.config/claudex"

fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$CLAUDEX_CORE" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$TEST_TMP/core-args"
if [ "${1:-}" = run ]; then
    sid=11111111-2222-3333-4444-555555555555
    mkdir -p "$HOME/.claude/projects/-tmp-project"
    printf '%s\n' '{"type":"assistant","message":{"model":"claudex-proxy"}}' \
        > "$HOME/.claude/projects/-tmp-project/$sid.jsonl"
fi
EOF
chmod +x "$CLAUDEX_CORE"

"$ROOT/files/claudex" --version
expected=--version
[[ $(cat "$TEST_TMP/core-args") == "$expected" ]] || fail "ordinary command was not forwarded"

"$ROOT/files/claudex" run commandcode --resume session-id
expected=$(printf 'run\ncommandcode\n--config\n%s\n--dangerously-skip-permissions\n--resume\nsession-id' "$CLAUDEX_CONFIG")
[[ $(cat "$TEST_TMP/core-args") == "$expected" ]] || fail "managed run arguments are wrong"
grep -q $'11111111-2222-3333-4444-555555555555\tcommandcode' "$CLAUDEX_SESSIONS" \
    || fail "managed run did not record its arbitrary profile"

"$ROOT/files/claudex" run foreign-profile
grep -qx 'foreign-profile' "$TEST_TMP/core-args" \
    || fail "explicit run did not preserve compatibility with foreign profiles"

"$ROOT/files/claudex" run commandcode --config="$TEST_TMP/custom.toml" --resume equals-config
expected=$(printf 'run\ncommandcode\n--dangerously-skip-permissions\n--config=%s\n--resume\nequals-config' "$TEST_TMP/custom.toml")
[[ $(cat "$TEST_TMP/core-args") == "$expected" ]] \
    || fail "--config=PATH caused a duplicate global config"

python3 - "$ROOT/files/claudex" "$ROOT/files/provider-registry.json" <<'PY'
import copy, importlib.machinery, importlib.util, json, sys
launcher, registry_path = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("claudex_provider_validation", launcher)
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
with open(registry_path) as handle:
    malformed = copy.deepcopy(json.load(handle))
del malformed["providers"]["grimoire"]["auth"]["key"]
try:
    module.validate_registry(malformed)
except module.UserError:
    pass
else:
    raise SystemExit("malformed shared provider descriptor passed validation")
PY

# Provision through local bare repositories. The fake setup captures the exact
# commit-pinned source URL; the token must occur only in the local auth store.
git init --bare -q --initial-branch=main "$TEST_TMP/remote.git"
git clone -q "$TEST_TMP/remote.git" "$TEST_TMP/seed"
cp -R "$ROOT/files" "$TEST_TMP/seed/files"
git -C "$TEST_TMP/seed" add files/provider-registry.json
git -C "$TEST_TMP/seed" -c user.name=test -c user.email=test@example.invalid commit -qm seed
git -C "$TEST_TMP/seed" push -q origin main
cat > "$TEST_TMP/setup" <<'EOF'
#!/bin/sh
printf '%s\n' "$LINUX_SETUP_SOURCE_URL" "$@" > "$TEST_TMP/setup-args"
EOF
chmod +x "$TEST_TMP/setup"

export CLAUDEX_SETUP_REPO="$TEST_TMP/remote.git"
export CLAUDEX_SETUP_BIN="$TEST_TMP/setup"
export CLAUDEX_RAW_REPO="https://raw.example.invalid/setup"

# Malformed local auth is rejected before the temporary clone can commit or
# push, and the corrupt bytes remain available for manual recovery.
mkdir -p "$(dirname "$CLAUDEX_AUTH_JSON")"
printf '{malformed auth\n' > "$CLAUDEX_AUTH_JSON"
cp "$CLAUDEX_AUTH_JSON" "$TEST_TMP/malformed-auth-before"
remote_before=$(git --git-dir="$TEST_TMP/remote.git" rev-parse main)
if python3 - "$ROOT/files/claudex" <<'PY'
import importlib.util, importlib.machinery, sys
path = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("claudex_malformed", path)
spec = importlib.util.spec_from_loader("claudex_malformed", loader)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
profile = {
    "name": "malformed", "provider_type": "OpenAICompatible",
    "base_url": "https://models.example.invalid/v1",
    "auth": {"type": "api-key", "store": "opencode", "key": "malformed"},
    "default_model": "model", "priority": 70, "enabled": True,
    "strip_params": "Auto",
    "models": {"haiku": "model", "sonnet": "model", "opus": "model"},
}
try:
    module.provision_profile(profile, "unwritten-secret")
except module.UserError:
    raise SystemExit(7)
PY
then
    fail "malformed auth store did not stop provisioning"
fi
cmp -s "$CLAUDEX_AUTH_JSON" "$TEST_TMP/malformed-auth-before" \
    || fail "malformed auth store was modified"
[[ $(git --git-dir="$TEST_TMP/remote.git" rev-parse main) == "$remote_before" ]] \
    || fail "malformed auth store allowed a remote commit"
[[ ! -e "$TEST_TMP/setup-args" ]] || fail "malformed auth store invoked setup"
rm -f "$CLAUDEX_AUTH_JSON"

secret='token-that-must-not-enter-git'
SECRET_TOKEN="$secret" python3 - "$ROOT/files/claudex" <<'PY'
import builtins, importlib.util, importlib.machinery, os, sys
path, token = sys.argv[1], os.environ["SECRET_TOKEN"]
loader = importlib.machinery.SourceFileLoader("claudex_launcher", path)
spec = importlib.util.spec_from_loader("claudex_launcher", loader)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
class Response:
    def __enter__(self): return self
    def __exit__(self, *args): pass
def fake_urlopen(request, timeout):
    assert request.get_header("Authorization") == "Bearer " + token
    assert timeout == 15
    response = Response()
    response.read = lambda: b'{"data":[{"id":"z-model"},{"id":"a-model"}]}'
    return response
module.urllib.request.urlopen = fake_urlopen
assert module.discover_models("https://models.example.invalid/v1/", token) == ["a-model", "z-model"]
# Exercise the full mapping dialogue without exposing or persisting its token.
answers = iter(["dialogtest", "https://models.example.invalid/v1", "y"])
builtins.input = lambda prompt="": next(answers)
module.getpass.getpass = lambda prompt="": token
module.discover_models = lambda base, supplied: ["model-small", "model-mid", "model-opus"]
selected = iter(["model-opus", "model-mid", "model-small"])
module.choose = lambda prompt, options: next(selected)
captured = {}
real_provision = module.provision_profile
module.provision_profile = lambda profile, supplied: captured.update(profile=profile, token=supplied)
module.add_profile(module.load_registry())
assert captured["profile"]["models"] == {
    "haiku": "model-small", "sonnet": "model-mid", "opus": "model-opus"
}
assert captured["token"] == token
module.provision_profile = real_provision
profile = {
    "name": "localtest", "provider_type": "OpenAICompatible",
    "base_url": "https://models.example.invalid/v1",
    "auth": {"type": "api-key", "store": "opencode", "key": "localtest"},
    "default_model": "model-opus", "priority": 70, "enabled": True,
    "strip_params": "Auto",
    "models": {"haiku": "model-small", "sonnet": "model-mid", "opus": "model-opus"},
}
module.provision_profile(profile, token)
PY

commit=$(git --git-dir="$TEST_TMP/remote.git" rev-parse main)
head -1 "$TEST_TMP/setup-args" | grep -q "https://raw.example.invalid/setup/$commit" \
    || fail "setup was not pinned to the pushed commit"
tail -n +2 "$TEST_TMP/setup-args" | diff -u <(printf 'update\nclaudex\n') - \
    || fail "setup invocation is wrong"
grep -q "$secret" "$CLAUDEX_AUTH_JSON" || fail "token was not stored locally after push"
if git --git-dir="$TEST_TMP/remote.git" grep -F "$secret" main; then
    fail "token entered Git"
fi
if grep -R -F "$secret" "$TEST_TMP/seed" >/dev/null; then
    fail "token entered a repository worktree"
fi

# A rejected fast-forward push leaves both auth and installed config untouched.
cat > "$TEST_TMP/remote.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TEST_TMP/remote.git/hooks/pre-receive"
cp "$CLAUDEX_AUTH_JSON" "$TEST_TMP/auth-before-reject"
printf 'sentinel\n' > "$CLAUDEX_CONFIG"
if python3 - "$ROOT/files/claudex" <<'PY'
import importlib.util, importlib.machinery, sys
path = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("claudex_reject", path)
spec = importlib.util.spec_from_loader("claudex_reject", loader)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
profile = {
    "name": "rejected", "provider_type": "OpenAICompatible",
    "base_url": "https://models.example.invalid/v1",
    "auth": {"type": "api-key", "store": "opencode", "key": "rejected"},
    "default_model": "model", "priority": 60, "enabled": True,
    "strip_params": "Auto",
    "models": {"haiku": "model", "sonnet": "model", "opus": "model"},
}
try:
    module.provision_profile(profile, "rejected-secret")
except module.UserError:
    raise SystemExit(7)
PY
then
    fail "rejected push reported success"
fi
cmp -s "$CLAUDEX_AUTH_JSON" "$TEST_TMP/auth-before-reject" || fail "rejected push changed local auth"
[[ $(cat "$CLAUDEX_CONFIG") == sentinel ]] || fail "rejected push changed installed config"
if git --git-dir="$TEST_TMP/remote.git" grep -F rejected-secret main; then
    fail "rejected token entered Git"
fi

echo "claudex launcher tests passed"
