#!/usr/bin/env bash
# Local plugin discovery and Claude reconciliation, without touching a real HOME.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HARNESSES_MANIFEST="$ROOT/files/harnesses-manifest.json"
mkdir -p "$HOME"
python3 - "$ROOT/files/harnesses" <<'PY'
import contextlib, io, json, os, runpy, sys
from pathlib import Path
from unittest import mock
ns = runpy.run_path(sys.argv[1], run_name="local_plugin_test")
g = ns['local_plugin_mcp_servers'].__globals__
home = Path.home()
root = home/'.codex/plugins/cache/openai-bundled/unified-computer-use'
node = home/'ChatGPT App/node'
node.parent.mkdir()
node.write_text('fixture')
node.chmod(0o755)
def install(version, tag):
    directory = root/version
    directory.mkdir(parents=True)
    entry = {'command': str(node), 'args': ['/app/cua-repl.mjs', tag],
             'env': {'CODEX_HOME': str(home/'.codex'), 'VALUE': 'spaces and "quotes"'},
             'enabled': True, 'startup_timeout_sec': 120, 'env_vars': []}
    (directory/'.mcp.json').write_text(json.dumps({'mcpServers': {'cua_repl': entry}}))
    return directory, entry
install('26.9.1', 'old')
latest, entry = install('26.10.1', 'new')
install('not-a-version', 'ignored')
with mock.patch.dict(g, _is_macos=lambda: False):
    assert ns['local_plugin_mcp_servers']() == []
with mock.patch.dict(g, _is_macos=lambda: True):
    servers = ns['local_plugin_mcp_servers']()
    assert len(servers) == 1
    server = servers[0]
    want = {'type': 'stdio', **{k: entry[k] for k in ('command', 'args', 'env')}}
    assert ns['_claude_mcp_entry'](server) == want
    assert ns['mcp_surfaces'](server) == ['claude']
    assert ns['mcp_grants'](servers) == ['mcp__cua_repl__*']
    with mock.patch.dict(g, hub_mcp_servers=lambda context: []):
        assert server in ns['all_mcp_servers']({})
    # Reconciliation changes a stale user entry, then becomes idempotent.
    calls = []
    config = home/'.claude.json'
    config.write_text(json.dumps({'mcpServers': {'cua_repl': {'type': 'stdio', 'command': 'old'}}}))
    with mock.patch.dict(g, _claude_mcp_scope=lambda name: 'user'), \
         mock.patch.object(g['subprocess'], 'run', side_effect=lambda argv, **kw: calls.append(argv)):
        ns['_claude_mcp_reconcile'](server)
        assert calls[0] == ['claude', 'mcp', 'remove', 'cua_repl', '-s', 'user']
        assert json.loads(calls[1][-1]) == want
        calls.clear()
        config.write_text(json.dumps({'mcpServers': {'cua_repl': want}}))
        ns['_claude_mcp_reconcile'](server)
        assert not calls
        with mock.patch.dict(g, _claude_mcp_scope=lambda name: 'project'):
            ns['_claude_mcp_reconcile'](server)
            assert not calls
    # Invalid newest versions never fall back to stale cached launch settings.
    original = (latest/'.mcp.json').read_text()
    for content in ('{', '{}', json.dumps({'mcpServers': {'cua_repl': {**entry, 'enabled': False}}}),
                    json.dumps({'mcpServers': {'cua_repl': {**entry, 'args': ['${PLUGIN_ROOT}/x']}}}),
                    json.dumps({'mcpServers': {'cua_repl': {**entry, 'env_vars': ['TOKEN']}}})):
        (latest/'.mcp.json').write_text(content)
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            assert ns['local_plugin_mcp_servers']() == []
        assert 'existing Claude registration preserved' in errors.getvalue()
        assert json.loads(config.read_text())['mcpServers']['cua_repl'] == want
    (latest/'.mcp.json').write_text(original)
    node.chmod(0o644)
    with contextlib.redirect_stderr(io.StringIO()):
        assert ns['local_plugin_mcp_servers']() == []
    node.chmod(0o755)
    # Discovery stays at the same durable path in shells and scheduled jobs.
    with mock.patch.dict(os.environ, CODEX_HOME=str(home/'other-codex')):
        assert ns['local_plugin_mcp_servers']() == servers
    root.rename(root.with_name('uninstalled'))
    assert ns['local_plugin_mcp_servers']() == []
print('local plugin MCP ok')
PY
