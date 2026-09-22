#!/usr/bin/env bash
# `harnesses update` must not treat exit 0 as proof that anything changed.
# A Homebrew-managed opencode answers `opencode upgrade` with "already
# installed" and exits 0 while a newer release sits in the tap, so the run
# reads the harness version on both sides and reports what actually moved.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HARNESSES_MANIFEST="$ROOT/files/harnesses-manifest.json"
mkdir -p "$HOME/.local/bin"

python3 - "$ROOT/files/harnesses" <<'PY'
import io, os, runpy, sys
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

payload = sys.argv[1]
HOME = Path(os.environ["HOME"])
ns = runpy.run_path(payload, run_name="harness_update_versions_test")
cmd_update = ns["cmd_update"]
G = cmd_update.__globals__   # the live module globals the function reads

def fail(msg):
    raise SystemExit("FAIL: " + msg)

# Three stub harnesses standing in for the three outcomes a real run has:
# one that genuinely upgrades, one whose updater exits 0 and changes nothing,
# and one whose updater fails outright.
bindir = HOME/".local/bin"
def stub(name, versions, rc=0):
    """A fake harness whose --version walks `versions` as the updater runs."""
    state = bindir/(name + ".version")
    state.write_text(versions[0])
    path = bindir/name
    path.write_text(
        "#!/usr/bin/env bash\n"
        'if [ "$1" = "--version" ]; then cat %s; exit 0; fi\n'
        "printf '%%s' %s > %s\n"
        "exit %d\n" % (str(state), repr(versions[-1]), str(state), rc)
    )
    path.chmod(0o755)
    return str(path)

specs = {
    "moved":     stub("moved", ["1.0.0", "1.1.0"]),
    "stuck":     stub("stuck", ["1.18.26", "1.18.26"]),
    "broken":    stub("broken", ["0.1.0", "0.1.0"], rc=1),
}
G["harnesses"] = lambda: [(n, {"updateArgs": "update"}) for n in specs]
G["harness_resolve"] = lambda name, spec: specs.get(name)

out = io.StringIO(); err = io.StringIO()
with redirect_stdout(out), redirect_stderr(err):
    rc = cmd_update([])
text, errtext = out.getvalue(), err.getvalue()

if "1.0.0 -> 1.1.0" not in text:
    fail("a real upgrade was not reported as a version transition:\n" + text)
if "1.18.26 (unchanged)" not in text:
    fail("an updater that changed nothing was not reported as unchanged:\n" + text)
if "Already current, or the updater did nothing: stuck" not in text:
    fail("the no-op harness was not named in the summary:\n" + text)
if "moved" in text.split("Already current")[1]:
    fail("a harness that really upgraded was listed as unchanged:\n" + text)
# A failing updater is still a failure, and it must not also be called
# unchanged -- that would report one problem as two.
if "broken" in text.split("Already current")[1]:
    fail("a failed harness was also counted as unchanged:\n" + text)
if "harness(es) could not be updated: broken" not in errtext:
    fail("a failing updater was not reported as failed:\n" + errtext)
if rc == 0:
    fail("cmd_update returned success despite a failed harness")

print("ok: harnesses update reports version movement, no-ops, and failures")
PY
