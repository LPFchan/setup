#!/usr/bin/env bash
# Keepout reconciliation and fail-open shell behavior, entirely in scratch HOME.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HARNESSES_MANIFEST="$ROOT/files/harnesses-manifest.json"
mkdir -p "$HOME"
python3 - "$ROOT/files/harnesses" <<'PY'
import json, os, runpy, shutil, subprocess, sys, tomllib
from pathlib import Path
from unittest import mock

ns = runpy.run_path(sys.argv[1], run_name="keepout_test")
g = ns['cmd_settings'].__globals__
home = Path.home()
command = ns['MANIFEST']['keepout']['command']
marker = ns['KEEPOUT_MARKER']
user = {'type': 'command', 'command': 'echo operator-hook', 'timeout': 7}
old = {'type': 'command', 'command': 'curl https://' + marker, 'async': True}
initial = {
    'custom': 'preserved',
    'hooks': {
        'UserPromptSubmit': [
            {'matcher': '*', 'hooks': [user, old], 'custom': 'shared-group'},
            {'hooks': [old]},
        ],
        'Stop': [{'hooks': [user]}],
    },
}
claude = ns['CLAUDE_SETTINGS']
codex = ns['CODEX_HOOKS']
kimi = ns['KIMI_CONFIG']
for path in (claude, codex, kimi):
    path.parent.mkdir(parents=True, exist_ok=True)
claude.write_text(json.dumps(initial))
codex.write_text(json.dumps(initial))
# config.toml is not needed for current Codex hooks, and stays byte-identical.
codex_config = ns['CODEX_CONFIG']
codex_config.write_text('model = "operator-model"\n[features]\nfast_mode = true\n')
codex_original = codex_config.read_bytes()
kimi_user = '''# Personal configuration
default_model = "operator-model"
[[hooks]]
event = "UserPromptSubmit"
command = "echo operator-hook"
timeout = 7
[[hooks]]
event = "Notification"
matcher = "task.completed"
command = "echo notification"
'''
kimi.write_text(kimi_user + '\n# BEGIN harnesses:keepout\n[[hooks]]\nevent = "UserPromptSubmit"\ncommand = ' + json.dumps(old['command']) + '\n# END harnesses:keepout\n')
kimi_original = tomllib.loads(kimi_user)

# Exercise the settings entrypoint even when Auth is unavailable. Hooks do not
# need a login at installation time; credentials are resolved on each prompt.
with mock.patch.dict(g, common_auth_context=lambda: (_ for _ in ()).throw(ns['CommonAuthError']('offline')),
                     _effort_descriptors_by_slug=lambda: {}), \
     mock.patch.dict(os.environ, TODAY_KEEPOUT_EXEMPT='1'):
    assert ns['cmd_settings']([]) == 1  # existing MCP-grants failure is reported

for path in (claude, codex):
    result = json.loads(path.read_text())
    assert result['custom'] == initial['custom']
    assert result['hooks']['Stop'] == initial['hooks']['Stop']
    assert result['hooks']['UserPromptSubmit'][0] == {
        'matcher': '*', 'hooks': [user], 'custom': 'shared-group',
    }
    handlers = [h for group in result['hooks']['UserPromptSubmit'] for h in group['hooks']]
    managed = [h for h in handlers if marker in h['command']]
    assert managed == [{'type': 'command', 'command': command}]
assert tomllib.loads(kimi.read_text()) == {
    **kimi_original, 'hooks': kimi_original['hooks'] + [{'event': 'UserPromptSubmit', 'command': command}],
}
assert codex_config.read_bytes() == codex_original
assert not (home/'.gemini').exists()
for directory in ('.grok', '.hermes', '.config/muse', '.config/opencode'):
    assert not (home/directory).exists(), directory

# Second pass is byte-identical. A changed command replaces, never duplicates.
def reconcile():
    ns['_write_claude_settings']([])
    ns['_write_codex_keepout']()
    ns['_write_kimi_keepout']()

before = {p: p.read_bytes() for p in (claude, codex, kimi)}
reconcile()
assert before == {p: p.read_bytes() for p in before}
g['MANIFEST']['keepout']['command'] = command + ' # revised'
reconcile()
for path in (claude, codex):
    groups = json.loads(path.read_text())['hooks']['UserPromptSubmit']
    managed = [h for group in groups for h in group['hooks'] if ns['_is_keepout_hook'](h)]
    assert [h['command'] for h in managed] == [command + ' # revised']
assert [h['command'] for h in tomllib.loads(kimi.read_text())['hooks'] if ns['_is_keepout_hook'](h)] == [command + ' # revised']

g['MANIFEST']['keepout']['enabled'] = False
reconcile()
for path in (claude, codex):
    result = json.loads(path.read_text())
    assert result['hooks']['UserPromptSubmit'] == [{
        'matcher': '*', 'hooks': [user], 'custom': 'shared-group',
    }]
    assert result['hooks']['Stop'] == initial['hooks']['Stop']
assert tomllib.loads(kimi.read_text()) == kimi_original
before = {p: p.read_bytes() for p in (claude, codex, kimi)}
reconcile()
assert before == {p: p.read_bytes() for p in before}

# Removing the only managed group leaves unrelated keys; disabled fresh HOME
# creates no Codex or Kimi hook files.
solo = {'hooks': {'UserPromptSubmit': [{'hooks': [old]}]}, 'keep': True}
ns['_merge_keepout_hooks'](solo)
assert solo == {'keep': True}
codex.unlink()
kimi.unlink()
ns['_write_codex_keepout']()
ns['_write_kimi_keepout']()
assert not codex.exists() and not kimi.exists()
g['MANIFEST']['keepout'].update(enabled=True, command=command)
print('keepout hooks: add/preserve/replace/idempotence/disable ok (Claude, Codex, Kimi)')

# Execute the actual shared command in each available POSIX-compatible shell.
# Stubs emulate auth/curl failures, including failure after emitting a lock body.
bin_dir = home/'stubs'
bin_dir.mkdir()
auth = bin_dir/'auth'
auth.write_text('''#!/bin/sh
[ "$*" = "token --cached today" ] || exit 99
printf '%s' "${AUTH_BODY-test-token}"
echo auth-diagnostic >&2
exit "${AUTH_RC:-0}"
''')
curl = bin_dir/'curl'
curl.write_text('''#!/bin/sh
printf '%s\\n' "$@" > "$HOME/curl-args"
/bin/cat > "$HOME/curl-stdin"
printf '%s|%s' "${CURL_BODY-}" "${HTTP_CODE:-200}"
echo curl-diagnostic >&2
exit "${CURL_RC:-0}"
''')
for path in (auth, curl):
    path.chmod(0o755)
awk = bin_dir/'awk'
awk.symlink_to(shutil.which('awk'))
env = {**os.environ, 'PATH': str(bin_dir)}
for key in ('TODAY_KEEPOUT_EXEMPT', 'AUTH_RC', 'AUTH_BODY', 'CURL_RC', 'CURL_BODY', 'HTTP_CODE'):
    env.pop(key, None)
lock = 'sleep until 12:00 per today keepout'
cases = [
    ({}, 0, ''),
    ({'CURL_BODY': ' \n\t\n'}, 0, ''),
    ({'CURL_BODY': lock + '\n'}, 2, lock + '\n'),
    ({'CURL_BODY': lock, 'TODAY_KEEPOUT_EXEMPT': '1'}, 0, ''),
    *[({'AUTH_RC': str(rc), 'CURL_BODY': lock}, 0, '') for rc in (1, 2, 3, 4, 5, 127)],
    *[({'HTTP_CODE': str(rc), 'CURL_BODY': lock}, 0, '') for rc in (000, 301, 302, 304, 401, 403, 500)],
    *[({'CURL_RC': str(rc), 'CURL_BODY': lock}, 0, '') for rc in (2, 6, 7, 22, 28, 35, 56, 127)],
]
shells = [shutil.which(s) for s in ('sh', 'bash', 'zsh') if shutil.which(s)]
for shell in shells:
    for extra, expected_rc, expected_err in cases:
        args = home/'curl-args'
        args.unlink(missing_ok=True)
        result = subprocess.run([shell, '-c', command], env={**env, **extra}, text=True, capture_output=True)
        assert (result.returncode, result.stdout, result.stderr) == (expected_rc, '', expected_err), (shell, extra, result)
        if extra.get('TODAY_KEEPOUT_EXEMPT') or extra.get('AUTH_RC'):
            assert not args.exists(), 'curl ran despite exemption/auth failure'
        if args.exists():
            argv = args.read_text().splitlines()
            assert argv == ['-fsS', '-m', '2', '-w', '|%{http_code}', '-H', '@-',
                            '-H', 'Accept: text/plain', 'https://' + marker]
            # The bearer travels on stdin, not in curl's argv.
            assert (home/'curl-stdin').read_text() == 'Authorization: Bearer test-token\n'
    for missing in (auth, curl, awk):
        hidden = missing.with_name(missing.name + '.hidden')
        missing.rename(hidden)
        result = subprocess.run([shell, '-c', command], env={**env, 'CURL_BODY': lock}, text=True, capture_output=True)
        hidden.rename(missing)
        assert result.returncode == 0 and not result.stdout, (shell, missing, result)
print('keepout command: free/locked/exempt/auth errors/HTTP errors/partial responses/missing tools ok (' + ', '.join(Path(s).name for s in shells) + ')')
PY
