#!/usr/bin/env bash
# Administrative Claude processes must not rotate the login used by T3.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import json, os, pathlib, runpy, sys, tempfile

root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory() as tmp:
    home = pathlib.Path(tmp)
    os.environ["HOME"] = tmp
    os.environ["HARNESSES_MANIFEST"] = str(root/"files/harnesses-manifest.json")
    os.environ.pop("CLAUDE_CODE_SIMPLE", None)
    bindir = home/".local/bin"
    bindir.mkdir(parents=True)
    creds = home/".claude/.credentials.json"
    creds.parent.mkdir()
    initial = {"claudeAiOauth": {"accessToken": "expired", "refreshToken": "rejected", "expiresAt": 1}}
    creds.write_text(json.dumps(initial))
    stub = '''#!/usr/bin/env python3
import json, os, pathlib, sys
h = pathlib.Path.home()
a = sys.argv[1:]
if a == ["--version"]:
    print("2.1.284")
    raise SystemExit
simple = os.environ.get("CLAUDE_CODE_SIMPLE")
with (h/"calls.jsonl").open("a") as f:
    f.write(json.dumps({"args": a, "simple": simple}) + "\\n")
if simple != "1":
    (h/".claude/.credentials.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": "", "refreshToken": "", "expiresAt": 0}}))
state_path = h/"mcp.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {}
if a[:2] == ["mcp", "get"]:
    server = state.get(a[2])
    if server is None:
        print("No MCP server named " + a[2])
        raise SystemExit(1)
    print("Scope: User config\\nURL: " + server)
elif a[:2] == ["mcp", "add"]:
    state[a[4]] = a[7]
    state_path.write_text(json.dumps(state))
elif a[:2] == ["mcp", "remove"]:
    state.pop(a[2], None)
    state_path.write_text(json.dumps(state))
'''
    claude = bindir/"claude"
    claude.write_text(stub)
    claude.chmod(0o755)
    ns = runpy.run_path(str(root/"files/harnesses"), run_name="maintenance_oauth_test")
    g = ns["cmd_mcp"].__globals__
    server = {"name": "managed", "url": "https://new.invalid/mcp", "auth": "none"}
    ns["_claude_mcp_reconcile"](server)  # missing -> get + add
    ns["_claude_mcp_reconcile"](server)  # current -> get
    (home/"mcp.json").write_text(json.dumps({"managed": "https://old.invalid/mcp", "retired": "https://retired.invalid/mcp"}))
    ns["_claude_mcp_reconcile"](server)  # drift -> get + remove + add
    g["MANIFEST"] = {"retiredMcpServers": ["retired"]}
    g["common_auth_context"] = lambda: {"origin": "https://auth.invalid", "subject": "test"}
    g["all_mcp_servers"] = lambda context: []
    g["_is_macos"] = lambda: False
    assert ns["cmd_mcp"]([]) == 0  # retired -> get + remove
    g["harnesses"] = lambda: [("claude", {"updateArgs": "update"})]
    g["harness_resolve"] = lambda name, spec: str(claude)
    assert ns["cmd_update"](["claude"]) == 0
    assert json.loads(creds.read_text()) == initial, "maintenance erased the shared OAuth login"
    calls = [json.loads(line) for line in (home/"calls.jsonl").read_text().splitlines()]
    assert len(calls) == 9, calls
    assert all(call["simple"] == "1" for call in calls), calls
    assert "retired" not in json.loads((home/"mcp.json").read_text())
    assert os.environ.get("CLAUDE_CODE_SIMPLE") is None, "minimal mode leaked into interactive launches"
    print("ok: MCP enrollment, reconciliation, retirement, and update preserve the Claude login")
PY
