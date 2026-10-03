#!/usr/bin/env bash
# Every harness carries a first-party installer, but a bare `harnesses install`
# must still only install the ones marked default, or every machine would pick
# up all nine. t3 installed through npx (the older Linux route) has no
# ~/.local/bin/t3, only ~/.t3/runtime/versions/<v>/t3, and the newest of those
# is the copy `harnesses update` must run.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HARNESSES_MANIFEST="$ROOT/files/harnesses-manifest.json"
export PATH="/usr/bin:/bin"
mkdir -p "$HOME"

python3 - "$ROOT/files/harnesses" <<'PY'
import io, json, os, runpy, sys
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

payload = sys.argv[1]
HOME = Path(os.environ["HOME"])
ns = runpy.run_path(payload, run_name="harness_install_resolve_test")
G = ns["cmd_install"].__globals__

def fail(msg):
    raise SystemExit("FAIL: " + msg)

manifest = json.load(open(os.environ["HARNESSES_MANIFEST"]))
for h in manifest["harnesses"]:
    if not h.get("install", "").strip():
        fail("%s has no installer" % h["name"])
    if h.get("viaNpx"):
        fail("%s still updates through npx" % h["name"])

# Bare install: only default harnesses are attempted. Stub them as present so
# nothing is actually installed.
G["harness_resolve"] = lambda name, spec: "/stub/" + name
out = io.StringIO()
with redirect_stdout(out), redirect_stderr(io.StringIO()):
    G["cmd_install"]([])
attempted = {l.split(":")[0].strip() for l in out.getvalue().splitlines()
             if "already installed" in l}
defaults = {h["name"] for h in manifest["harnesses"] if h.get("default")}
if attempted != defaults or defaults != {"claude", "codex"}:
    fail("bare install attempted %s, expected %s" % (sorted(attempted), sorted(defaults)))

# t3 resolves through the runtime versions glob, newest version first (0.0.45
# sorts above 0.0.9 by number, not by string).
G["harness_resolve"] = ns["harness_resolve"]
t3 = dict(ns["harnesses"]())["t3"]
if G["harness_resolve"]("t3", t3) is not None:
    fail("t3 resolved on a machine without it")
for v in ("0.0.9", "0.0.45", "0.0.40"):
    p = HOME/".t3/runtime/versions"/v/"t3"
    p.parent.mkdir(parents=True)
    p.write_text("#!/bin/sh\n"); p.chmod(0o755)
got = G["harness_resolve"]("t3", t3)
if got != str(HOME/".t3/runtime/versions/0.0.45/t3"):
    fail("t3 resolved to %s, expected the newest runtime version" % got)

# The installer's own symlink wins over the runtime glob.
link = HOME/".local/bin/t3"
link.parent.mkdir(parents=True); link.write_text("#!/bin/sh\n"); link.chmod(0o755)
if G["harness_resolve"]("t3", t3) != str(link):
    fail("~/.local/bin/t3 did not take precedence over the runtime glob")

print("ok: every harness has an installer, bare install sticks to defaults, t3 resolves without npx")
PY
