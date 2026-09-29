#!/usr/bin/env bash
# `harnesses update` must act on the copy of a harness the operator actually
# runs. _heal_path used to prepend every nvm version on the machine, newest
# first, ahead of the caller's own PATH: `harnesses update codex` then read and
# upgraded a stale copy under an unused node install and reported a version
# transition for it, while ~/.local/bin/codex -- the symlink the operator's
# shell resolves -- sat untouched at an older version.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HARNESSES_MANIFEST="$ROOT/files/harnesses-manifest.json"
mkdir -p "$HOME/.local/bin"

# Two node installs, the way any machine that has run `nvm install` twice
# looks: the operator's active one owns the codex on PATH, and a newer but
# unused one carries a stale copy of the same harness.
export IN_USE="$HOME/.nvm/versions/node/v22.0.0"
export STALE="$HOME/.nvm/versions/node/v24.0.0"
export RECORD="$TMP/npm-seen"
export DECOY_NPM="$TMP/sysbin/npm"

# An npm whose only job is to say which one the updater found. codex and
# claude self-update through `npm install -g`, so this is what decides where
# the new version lands.
make_npm() {
    mkdir -p "$(dirname "$1")"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$1"
    chmod +x "$1"
}

# A harness laid out the way npm lays one out: the executable lives in the
# install's node_modules and bin/ holds only a symlink to it.
make_codex() {
    local prefix="$1" next="$2" pkg
    pkg="$prefix/lib/node_modules/@openai/codex/bin"
    mkdir -p "$pkg" "$prefix/bin"
    cat > "$pkg/codex.js" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'codex-cli %s\n' "\$(cat "$prefix/.version")"; exit 0; fi
if [ "\$1" = "update" ]; then
    command -v npm >> "$RECORD"
    printf '%s' '$next' > "$prefix/.version"
    exit 0
fi
exit 1
EOF
    chmod +x "$pkg/codex.js"
    ln -sf ../lib/node_modules/@openai/codex/bin/codex.js "$prefix/bin/codex"
    make_npm "$prefix/bin/npm"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$prefix/bin/node"
    chmod +x "$prefix/bin/node"
}

# A system-wide copy of the same harness, the kind a package manager drops in
# /usr/local/bin. The scheduled run inherits a PATH that carries it and none of
# the operator's own directories, and must still update the operator's copy.
make_system_codex() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf 'codex-cli 0.100.0\n'; exit 0; fi
printf 'the system-wide copy was updated\n' >> "$RECORD"
exit 0
EOF
    chmod +x "$1"
}

make_codex "$IN_USE" 0.159.0
make_codex "$STALE" 0.160.0
ln -sf "$IN_USE/bin/codex" "$HOME/.local/bin/codex"
make_npm "$DECOY_NPM"
make_system_codex "$TMP/usrlocal/codex"

cat > "$TMP/probe.py" <<'PY'
import io, os, runpy, sys
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

payload, scenario = sys.argv[1], sys.argv[2]
in_use, stale = Path(os.environ["IN_USE"]), Path(os.environ["STALE"])
record = Path(os.environ["RECORD"])

def fail(msg):
    raise SystemExit("FAIL: [%s] %s" % (scenario, msg))

# Each scenario starts from the same drift: the copy in use is one release
# behind, the copy nobody runs is further behind still.
(in_use/".version").write_text("0.158.0")
(stale/".version").write_text("0.155.1")
record.write_text("")

ns = runpy.run_path(payload, run_name="harness_path_precedence_test")
spec = dict(ns["harnesses"]())["codex"]

resolved = ns["harness_resolve"]("codex", spec)
want = str(Path(os.environ["HOME"])/".local/bin/codex")
if resolved != want:
    fail("resolved %s, not the copy the operator runs (%s)" % (resolved, want))
version = ns["harness_version"](resolved)
if version != "codex-cli 0.158.0":
    fail("read the version of some other copy: %r" % version)

out, err = io.StringIO(), io.StringIO()
with redirect_stdout(out), redirect_stderr(err):
    rc = ns["cmd_update"](["codex"])
text = out.getvalue()
if rc != 0:
    fail("update failed:\n" + text + err.getvalue())
if "codex-cli 0.158.0 -> codex-cli 0.159.0" not in text:
    fail("the copy in use was not the one reported as upgraded:\n" + text)
if (in_use/".version").read_text() != "0.159.0":
    fail("the copy on PATH stayed at %s" % (in_use/".version").read_text())
if (stale/".version").read_text() != "0.155.1":
    fail("the update landed on the node install nobody runs")

# The harness's own updater shells out to npm, so it has to be handed the npm
# of the install it lives in -- its own directory (~/.local/bin) has none, and
# whatever npm happens to be first on PATH would install somewhere else.
seen = [os.path.realpath(p) for p in record.read_text().split()]
if seen != [os.path.realpath(in_use/"bin/npm")]:
    fail("the updater found npm at %r, not its own install's" % seen)

print("ok: [%s] update acts on the harness the operator runs" % scenario)
PY

# A login shell: ~/.local/bin leads, and one node install is active. Neither
# the unused newer install nor the system-wide copy may displace them.
PATH="$HOME/.local/bin:$IN_USE/bin:$TMP/usrlocal:/usr/bin:/bin" \
    python3 "$TMP/probe.py" "$ROOT/files/harnesses" "login shell"

# The scheduled run: systemd hands us a PATH with none of the user's own
# directories on it, a system-wide codex, and a system npm that would install
# as root. _heal_path has to add the user's directories back ahead of all of
# that, and the updater still has to end up on the npm of the install it is
# updating.
PATH="$TMP/sysbin:$TMP/usrlocal:/usr/bin:/bin" \
    python3 "$TMP/probe.py" "$ROOT/files/harnesses" "login-less PATH"
