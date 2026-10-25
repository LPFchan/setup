#!/usr/bin/env python3
"""Validate fleet's self-update and self-install provisioning without changing host tools."""
import base64
import contextlib
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("fleet_upgrade_test", str(ROOT/"files/fleet"))
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec)
loader.exec_module(fleet)

with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    fleet.HOME = work
    fleet.STATE_HOME = work/"state"
    payload = {name: (ROOT/"files"/name).read_bytes() for name in
               ("fleet", "auth", "fleet-manifest.json", "fleet-providers.py", "provider-registry.json")}
    bin_dir = work/".local/bin"
    targets = {"fleet": bin_dir/"fleet", "auth": bin_dir/"auth",
               "fleet-manifest.json": work/".config/fleet/manifest.json",
               "fleet-providers.py": bin_dir/"fleet-providers.py",
               "provider-registry.json": work/".config/fleet/provider-defaults.json"}
    # A pre-provider installation has fleet/auth but no provider payload yet.
    for name in ("fleet", "auth"):
        targets[name].parent.mkdir(parents=True, exist_ok=True)
        targets[name].write_text("pass\n")
    def response(url, **kwargs):
        return io.BytesIO(payload[url.rsplit("/", 1)[1]])
    with patch.object(fleet, "_source_base", return_value="https://setup.test/commit"), \
         patch.object(fleet.urllib.request, "urlopen", side_effect=response), \
         contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        assert fleet._self_update() == 0
        assert all(path.read_bytes() == payload[name] for name, path in targets.items())
        if not fleet.WINDOWS:
            assert all(os.access(targets[name], os.X_OK) for name in ("fleet", "auth"))
        previous = {name: path.read_bytes() for name, path in targets.items()}
        payload["fleet"] = b"print('next version')\n"
        payload["fleet-providers.py"] = b"def broken("
        assert fleet._self_update() == 1
        assert all(path.read_bytes() == previous[name] for name, path in targets.items())

    # While setup's fleet module still owns fleet, fleet leaves updating to it.
    setup_state = fleet.STATE_HOME/"setup/script-state.tsv"
    setup_state.parent.mkdir(parents=True)
    setup_state.write_text("auth\tauth\tx\tx\nfleet\tfleet\tx\tx\n")
    with patch.object(fleet, "_self_update", side_effect=AssertionError("self-update under setup")), \
         contextlib.redirect_stderr(io.StringIO()):
        assert fleet.cmd_self_update() == 1
    setup_state.write_text("resume\tx\tx\tx\n")
    with patch.object(fleet, "_self_update", return_value=0):
        assert fleet.cmd_self_update() == 0

    # The nightly pass updates fleet first on every OS, unless setup still owns it.
    # An engine stands in: whether one is installed depends on the caller's
    # FLEET_PROVIDER_ENGINE (fleet-windows.py points it at a missing file).
    def nightly():
        events = []
        with patch.object(fleet, "_self_update", side_effect=lambda: events.append("update")), \
             patch.object(fleet, "provider_engine", return_value=object()), \
             patch.object(fleet, "cmd_sync", side_effect=lambda **kw: events.append(("sync", kw)) or 0), \
             patch.object(fleet, "cmd_update", side_effect=lambda _: events.append("harnesses") or 0), \
             patch.object(fleet, "refresh_provider_models", side_effect=lambda: events.append("models") or 0), \
             patch.object(fleet, "converge_ocx", side_effect=lambda: events.append("ocx")):  # never the host's proxy
            assert fleet.cmd_nightly() == 0
        return events
    for windows in (False, True):
        fleet.WINDOWS = windows
        events = nightly()
        assert events == ["update", ("sync", {"pull": True}), "models", "harnesses", "ocx"], (windows, events)
    setup_state.write_text("fleet\tfleet\tx\tx\n")
    events = nightly()
    assert events == [("sync", {"pull": True}), "models", "harnesses", "ocx"], events


    # fleet self-install, what the installers run: the payload (here from a local
    # checkout), PATH, sign-in, then the installed copy syncs and schedules. setup
    # still owning fleet (the state above) does not stop it.
    def self_install(windows, args=(), sync_rc=0):
        fleet.WINDOWS = windows
        runs = []
        def run(argv, **kwargs):
            runs.append(argv)
            return SimpleNamespace(returncode=sync_rc if "sync" in argv else 0)
        out = io.StringIO()
        with patch.object(fleet, "_source_base", return_value=str(ROOT)), \
             patch.object(fleet, "_auth", return_value=(1, "")), \
             patch.object(fleet.subprocess, "run", side_effect=run), \
             patch.dict(os.environ, {"SHELL": "/bin/zsh"}), \
             contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = fleet.cmd_self_install(list(args))
        return rc, runs, out.getvalue()
    for path in targets.values():
        path.unlink()
    rc, runs, out = self_install(False, ["--pull"])
    assert rc == 0 and all(path.read_bytes() == (ROOT/"files"/name).read_bytes() for name, path in targets.items())
    installed = [sys.executable, str(bin_dir/"fleet")]
    assert runs == [installed + ["sync", "--pull"], installed + ["schedule", "enable"]], runs
    assert "not signed in" in out
    assert "setup:path" in (work/".zshenv").read_text()
    rc, runs, out = self_install(False)
    assert rc == 0 and "fleet: updated" not in out and (work/".zshenv").read_text().count("setup:path >>>") == 1
    assert self_install(False, sync_rc=3)[0] == 0 and self_install(False, sync_rc=1)[0] == 1
    assert self_install(False, ["--push"])[0] == 2
    # bash: the login file, and ~/.bashrc, which a new terminal window reads; once each.
    bash_home = work/"bash-home"
    (bash_home/".local/bin").mkdir(parents=True)
    fleet.HOME, fleet.WINDOWS = bash_home, False
    with patch.dict(os.environ, {"SHELL": "/bin/bash"}), contextlib.redirect_stdout(io.StringIO()) as out:
        assert fleet._add_to_path() == 0 and fleet._add_to_path() == 0
    assert ".profile and " in out.getvalue() and ".bashrc;" in out.getvalue(), out.getvalue()
    for name in (".profile", ".bashrc"):
        assert (bash_home/name).read_text().count("setup:path >>>") == 1, name
    if sys.platform != "win32" and shutil.which("bash"):
        (bash_home/".local/bin/fleet").write_text("#!/bin/sh\n")
        (bash_home/".local/bin/fleet").chmod(0o755)
        found = subprocess.run(["bash", "-ic", "command -v fleet"], capture_output=True, text=True,
                               stdin=subprocess.DEVNULL, env={"HOME": str(bash_home), "PATH": "/usr/bin:/bin"})
        # The last line: the system's bash.bashrc may print a notice first.
        assert found.stdout.strip().splitlines()[-1:] == [str(bash_home/".local/bin/fleet")], (found.stdout, found.stderr)
    # An existing ~/.bash_login hides ~/.profile from login shells, so it gets the block.
    login_home = work/"bash-login-home"
    login_home.mkdir()
    (login_home/".bash_login").write_text("")
    fleet.HOME = login_home
    with patch.dict(os.environ, {"SHELL": "/bin/bash"}), contextlib.redirect_stdout(io.StringIO()):
        assert fleet._add_to_path() == 0
    assert "setup:path" in (login_home/".bash_login").read_text() and not (login_home/".profile").exists()
    fleet.HOME = work
    # Windows: cmd shims that run on this Python, and the user PATH through PowerShell.
    rc, runs, out = self_install(True)
    assert rc == 0
    for name in ("auth", "fleet"):
        assert (bin_dir/f"{name}.cmd").read_bytes() == f'@"{sys.executable}" -X utf8 "%~dp0{name}" %*\r\n'.encode()
    assert runs[0][0] == "powershell"
    script = base64.b64decode(runs[0][-1]).decode("utf-16-le")
    assert "SetEnvironmentVariable" in script and str(bin_dir) in script
    installed = [sys.executable, "-X", "utf8", str(bin_dir/"fleet")]
    assert runs[1:] == [installed + ["sync"], installed + ["schedule", "enable"]], runs
    fleet.WINDOWS = sys.platform == "win32"

    # Under `curl | sh` stdin is the pipe, so sign-in opens the terminal itself:
    # under a real pty, a missing session runs `auth login` on that terminal.
    if not fleet.WINDOWS:
        import pty
        log, stub = work/"login.log", work/"auth-stub"
        stub.write_text(f'#!/bin/sh\n[ "$1" = login ] || exit 1\n'
                        f'on=pipe; [ -t 0 ] && [ -t 1 ] && on=tty; echo "$1 $on" > "{log}"\n')
        stub.chmod(0o755)
        pid, terminal = pty.fork()
        if pid == 0:
            try:
                os.environ.pop("SETUP_BATCH", None)
                os.environ["FLEET_AUTH_BIN"] = str(stub)
                fleet._login_if_needed()
            finally:
                os._exit(0)
        while True:  # drain the terminal until the child closes it
            try:
                if not os.read(terminal, 1024):
                    break
            except OSError:
                break
        os.waitpid(pid, 0)
        assert log.exists() and log.read_text().split() == ["login", "tty"], \
            log.read_text() if log.exists() else "auth login never ran"

print("fleet self-update and self-install provisioning, atomicity, setup handover and nightly scheduling tests passed")
