#!/usr/bin/env python3
"""fleet on Windows, against a stand-in Auth: skills linked by junction, copies
of AGENTS.md in place of links, a token file of its own, LF-only writes, the msvcrt lock, and
only the harnesses with a windows block. Runs on Windows only (CI)."""
import base64
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile

if sys.platform != "win32":
    print("fleet-windows: skipped (not Windows)")
    sys.exit(0)

ROOT = pathlib.Path(__file__).resolve().parent.parent
TMP = pathlib.Path(tempfile.mkdtemp())
HOME, FAKE = TMP/"home", TMP/"fake"
STATE = HOME/".local/state"
for d in (HOME/".claude", FAKE, TMP/"ssh"):
    d.mkdir(parents=True)

AUTH = r'''
import base64, hashlib, json, os, sys
fake = os.environ["FAKE"]
args = sys.argv[1:]
if args[0] == "context":
    print(json.dumps({"origin": "https://auth.test", "subject": "7"})); sys.exit(0)
if args[0] == "token":
    print("tok-" + args[1]); sys.exit(0)
if args[0] != "request":
    sys.exit(0)
method, path = args[1], args[2]
body = json.load(sys.stdin) if len(args) > 3 else None
state = json.load(open(f"{fake}/server.json"))
sha = lambda b64: hashlib.sha256(base64.b64decode(b64)).hexdigest()
def out(value):
    json.dump(state, open(f"{fake}/server.json", "w")); print(json.dumps(value)); sys.exit(0)
if path == "/api/fleet":
    out({"version": "v", "self": {"served": True}, "keys": ["ssh-ed25519 AAAAPeer"], "hosts": []})
if path == "/api/services":
    out([{"key": "okdam.lost.plus", "mcp_url": "https://okdam.lost.plus/mcp", "token_key": "okdam-mcp"}])
if path == "/api/fleet/config":
    out({"counter": state["counter"], "version": "v%d" % state["counter"], "installs": [],
         "files": [{"path": p, "sha256": sha(f["content"]), "size": 1, "executable": f["executable"]}
                   for p, f in state["files"].items()]})
if path == "/api/fleet/config/fetch":
    out({"files": [{"path": p, "sha256": sha(state["files"][p]["content"]), **state["files"][p]}
                   for p in body["paths"]], "remaining": [], "missing": []})
if path == "/api/fleet/config/push":
    for f in body["put"]:
        state["files"][f["path"]] = {"content": f["content"], "executable": f["executable"]}
    for p in body["delete"]:
        state["files"].pop(p, None)
    state["counter"] += 1
    out({"counter": state["counter"], "version": "v%d" % state["counter"]})
print(json.dumps({"status": 404, "error": "no route " + path})); sys.exit(6)
'''
(TMP/"auth.py").write_text(AUTH)

env = {**os.environ, "HOME": str(HOME), "USERPROFILE": str(HOME), "XDG_STATE_HOME": str(STATE),
       "LOCALAPPDATA": str(HOME/"AppData/Local"), "APPDATA": str(HOME/"AppData/Roaming"),
       "FAKE": str(FAKE), "FLEET_AUTH_BIN": str(TMP/"auth.py"), "FLEET_SSH_DIR": str(TMP/"ssh"),
       "FLEET_MANIFEST": str(ROOT/"files/fleet-manifest.json"), "FLEET_PROVIDER_ENGINE": str(TMP/"not-installed.py"), "FLEET_SELF": "winbox",
       "PATH": os.pathsep.join([os.path.dirname(sys.executable), os.environ.get("SystemRoot", "C:/Windows") + "/System32"])}


def b64(text):
    return base64.b64encode(text.encode()).decode()


def server(files, counter):
    (FAKE/"server.json").write_text(json.dumps({"counter": counter, "files": {
        p: {"content": b64(c), "executable": x} for p, (c, x) in files.items()}}))


def server_files():
    return json.loads((FAKE/"server.json").read_text())["files"]


def fleet(*args, expect=0):
    # No -X utf8 here: fleet must turn UTF-8 mode on by itself.
    run = subprocess.run([sys.executable, str(ROOT/"files/fleet"), *args], env=env,
                         capture_output=True, text=True, encoding="utf-8")
    if expect is not None and run.returncode != expect:
        raise SystemExit(f"FAIL: fleet {' '.join(args)} -> {run.returncode}\n{run.stdout}{run.stderr}")
    return run


def check(ok, what):
    if not ok:
        raise SystemExit(f"FAIL: {what}")


AGENTS = HOME/".agents"
CLAUDE_MD, HOME_MD = HOME/".claude/CLAUDE.md", HOME/"AGENTS.md"
CLAUDE_MD.write_bytes(b"mine\n")
HOME_MD.write_bytes("be kind — always\n".encode())  # already the same as Auth's
server({"AGENTS.md": ("be kind — always\n", 0), "settings/tool.sh": ("echo hi\n", 1),
        "skills/notes/SKILL.md": ("notes\n", 0)}, 1)

fleet("sync")
check((AGENTS/"AGENTS.md").read_bytes() == "be kind — always\n".encode(), "AGENTS.md pulled as UTF-8 with LF")
check((AGENTS/"skills/notes/SKILL.md").read_bytes() == b"notes\n", "skills pulled")
builtin = AGENTS/"skills/fleet/SKILL.md"
check(builtin.read_text(encoding="utf-8").startswith("---\nname: fleet") and not os.access(builtin, os.W_OK),
      "built-in skill written read-only")
CLAUDE_SKILLS = HOME/".claude/skills"
check(os.path.realpath(CLAUDE_SKILLS/"notes") == os.path.realpath(AGENTS/"skills/notes")
      and (CLAUDE_SKILLS/"notes/SKILL.md").read_bytes() == b"notes\n", "skill reached through a junction")
check((CLAUDE_SKILLS/"fleet/SKILL.md").exists(), "built-in skill linked")
check(CLAUDE_MD.read_bytes() == (AGENTS/"AGENTS.md").read_bytes() and not CLAUDE_MD.is_symlink(), "CLAUDE.md copy")
check((HOME/".claude/CLAUDE.md.pre-agents.bak").read_bytes() == b"mine\n", "own CLAUDE.md kept as a backup")
check(HOME_MD.read_bytes() == (AGENTS/"AGENTS.md").read_bytes(), "~/AGENTS.md copy")
check((HOME/"AGENTS.md.pre-agents.bak").exists(), "an identical ~/AGENTS.md kept as a backup")
check(not (HOME/".codex/AGENTS.md").exists(), "a copy into a harness dir that is not there")
tokens = STATE/"fleet/mcp-tokens"
check(b"OKDAM_MCP_TOKEN=tok-okdam-mcp" in tokens.read_bytes() and b"\r" not in tokens.read_bytes(), "token file")
check(not (HOME/".zshenv").exists(), "a .zshenv written on Windows")
ssh_config = (TMP/"ssh/config").read_bytes()
check(b"\r" not in ssh_config and b"known_hosts.fleet" in ssh_config, "SSH config")
check(json.loads(fleet("mcp-headers", "bearer", "OKDAM_MCP_TOKEN").stdout)
      == {"Authorization": "Bearer tok-okdam-mcp"}, "mcp-headers reads the token file")

# Auth's AGENTS.md moves on: the copies follow, the backup stays.
server({**{p: (base64.b64decode(f["content"]).decode(), f["executable"]) for p, f in server_files().items()},
        "AGENTS.md": ("be kinder\n", 0)}, 2)
fleet("sync")
check(CLAUDE_MD.read_bytes() == b"be kinder\n" and HOME_MD.read_bytes() == b"be kinder\n", "copies updated")
check((HOME/".claude/CLAUDE.md.pre-agents.bak").read_bytes() == b"mine\n", "backup untouched")

# A local edit pushes and keeps Auth's executable bit; a new skill pushes too.
(AGENTS/"settings/tool.sh").write_bytes(b"echo bye\n")
(AGENTS/"skills/mine").mkdir(parents=True)
(AGENTS/"skills/mine/SKILL.md").write_bytes(b"local\n")
fleet("sync")
files = server_files()
check(base64.b64decode(files["settings/tool.sh"]["content"]) == b"echo bye\n" and files["settings/tool.sh"]["executable"],
      "push keeps the executable bit")
check(base64.b64decode(files["skills/mine/SKILL.md"]["content"]) == b"local\n", "new skill pushed")
check((CLAUDE_SKILLS/"mine/SKILL.md").read_bytes() == b"local\n", "new skill linked")
check(not any(p.startswith("skills/fleet/") for p in files), "built-in skill never pushed")

# An outdated built-in skill is replaced although it is read-only; a skill gone
# from Auth loses its junction.
builtin.chmod(0o644)
builtin.write_text("older", encoding="utf-8")
builtin.chmod(0o444)
server({p: (base64.b64decode(f["content"]).decode(), f["executable"]) for p, f in server_files().items()
        if p != "skills/notes/SKILL.md"}, 5)
fleet("sync")
check(builtin.read_text(encoding="utf-8").startswith("---\nname: fleet"), "built-in skill restored")
check(not os.path.lexists(CLAUDE_SKILLS/"notes") and not (AGENTS/"skills/notes").exists(), "junction dropped")
check(fleet("sync", "--check").returncode == 0, "nothing pending after a sync")

# Two passes at once wait for each other on the lock.
runs = [subprocess.Popen([sys.executable, str(ROOT/"files/fleet"), "sync"], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for _ in range(2)]
check(all(r.wait(timeout=120) == 0 for r in runs), "concurrent syncs")

# AGENTS.md gone from Auth: fleet's copies go, the user's file comes back.
server({p: (base64.b64decode(f["content"]).decode(), f["executable"]) for p, f in server_files().items()
        if p != "AGENTS.md"}, 9)
fleet("sync")
check(CLAUDE_MD.read_bytes() == b"mine\n" and HOME_MD.read_bytes() == "be kind — always\n".encode(),
      "copies removed, backups restored")

# The nightly task runs pythonw: no console, so output lands in sync.log.
pythonw = pathlib.Path(sys.executable).with_name("pythonw.exe")
if pythonw.exists():
    check(subprocess.run([str(pythonw), "-X", "utf8", str(ROOT/"files/fleet"), "sync"], env=env).returncode == 0,
          "sync under pythonw")
    check((STATE/"fleet/sync.log").read_text(encoding="utf-8").startswith("--- "), "pythonw output in sync.log")

check("Usage: fleet skills" in fleet("skills", "bogus", expect=2).stderr, "skills command offered")
unknown = fleet("install", "t3", expect=None)
check(unknown.returncode != 0 and "unknown harness" in unknown.stderr, "t3 offered on Windows")
# Provider caches use the Windows lock and native auth.json, without .zshenv.
provider_check = r'''
import pathlib, runpy, sys
m = runpy.run_path(sys.argv[1], run_name="provider_windows_test")
context = {"origin": "https://auth.test", "subject": "7"}
m["_save_cache"]({"demo": "fixture-key", "_fleet_account": context})
m["bind_account"](context)
m["_sync_mirrors"]()
assert m["cache_get"]("demo") == "fixture-key"
assert not pathlib.Path(m["ZSENV_PATH"]).exists()
m["bind_account"]({"origin": "https://auth.test", "subject": "8"})
assert not m["cache_get"]("demo")
assert "fixture-key" not in pathlib.Path(m["OLD_AUTH_PATH"]).read_text()
assert not pathlib.Path(m["ZSENV_PATH"]).exists()
'''
result = subprocess.run([sys.executable, "-c", provider_check, str(ROOT/"files/fleet-providers.py")],
                        env=env, capture_output=True, text=True)
check(result.returncode == 0, "provider Windows lock and account isolation: " + result.stderr)
result = subprocess.run([sys.executable, str(ROOT/"tests/fleet-self-update.py")],
                        env=env, capture_output=True, text=True)
check(result.returncode == 0, "fleet self-update: " + result.stdout + result.stderr)
# The cmd shims fleet self-install writes run fleet on this Python. The user PATH
# and the nightly task are left out: both would change the runner's own account.
shim_home = TMP/"shim"
add_to_path = r'''
import importlib.machinery, importlib.util, pathlib, sys
loader = importlib.machinery.SourceFileLoader("fleet_shim_test", sys.argv[1])
f = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(f)
f.HOME = pathlib.Path(sys.argv[2])
f._shell = lambda script: [sys.executable, "-c", "pass"]
sys.exit(f._add_to_path())
'''
result = subprocess.run([sys.executable, "-c", add_to_path, str(ROOT/"files/fleet"), str(shim_home)],
                        env=env, capture_output=True, text=True)
check(result.returncode == 0, "fleet shims: " + result.stderr)
(shim_home/".local/bin/fleet").write_bytes((ROOT/"files/fleet").read_bytes())
result = subprocess.run(["cmd", "/c", str(shim_home/".local/bin/fleet.cmd"), "skills", "bogus"],
                        env=env, capture_output=True, text=True, encoding="utf-8")
check(result.returncode == 2 and "Usage: fleet skills" in result.stderr, "fleet.cmd runs fleet: " + result.stderr)
result = subprocess.run([sys.executable, str(ROOT/"tests/provider-migration.py")],
                        env=env, capture_output=True, text=True)
check(result.returncode == 0, "one-off provider migration: " + result.stdout + result.stderr)
print("fleet-windows: ok")
