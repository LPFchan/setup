#!/usr/bin/env python3
"""Validate Windows payload provisioning without changing host tools."""
import contextlib
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("fleet_upgrade_test", str(ROOT/"files/fleet"))
spec = importlib.util.spec_from_loader(loader.name, loader)
fleet = importlib.util.module_from_spec(spec)
loader.exec_module(fleet)

with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    fleet.HOME = work
    fleet.MANIFEST_PATH = work/"config/manifest.json"
    fleet.PROVIDER_ENGINE = work/"bin/fleet-providers.py"
    fleet.PROVIDER_DEFAULTS = work/"config/provider-defaults.json"
    payload = {name: (ROOT/"files"/name).read_bytes() for name in
               ("fleet", "auth", "fleet-manifest.json", "fleet-providers.py", "provider-registry.json")}
    targets = {"fleet": work/".local/bin/fleet", "auth": work/".local/bin/auth",
               "fleet-manifest.json": fleet.MANIFEST_PATH,
               "fleet-providers.py": fleet.PROVIDER_ENGINE,
               "provider-registry.json": fleet.PROVIDER_DEFAULTS}
    # A pre-provider installation has fleet/auth but no provider payload yet.
    for name in ("fleet", "auth"):
        targets[name].parent.mkdir(parents=True, exist_ok=True)
        targets[name].write_text("pass\n")
    def response(url, **kwargs):
        return io.BytesIO(payload[url.rsplit("/", 1)[1]])
    with patch.object(fleet, "_source_base", return_value="https://setup.test/commit"), \
         patch.object(fleet.urllib.request, "urlopen", side_effect=response), \
         contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        fleet._self_update()
        assert all(path.read_bytes() == payload[name] for name, path in targets.items())
        previous = {name: path.read_bytes() for name, path in targets.items()}
        payload["fleet"] = b"print('next version')\n"
        payload["fleet-providers.py"] = b"def broken("
        fleet._self_update()
        assert all(path.read_bytes() == previous[name] for name, path in targets.items())

    fleet.WINDOWS = True
    scheduled = []
    with patch.object(fleet, "_schtasks", side_effect=lambda *args: scheduled.append(args) or 0), \
         patch.object(sys, "argv", [str(work/".local/bin/fleet")]):
        assert fleet.provider_schedule(True) == 0
    assert scheduled[0][0] == "/Create" and "__refresh-providers" in scheduled[0][-1]

    events = []
    with patch.object(fleet, "_self_update", side_effect=lambda: events.append("update")), \
         patch.object(fleet, "cmd_sync", side_effect=lambda **kw: events.append(("sync", kw)) or 0), \
         patch.object(fleet, "cmd_update", side_effect=lambda _: events.append("harnesses") or 0):
        assert fleet.cmd_nightly() == 0
    assert events == ["update", ("sync", {"pull": True}), "harnesses"]

print("fleet self-update provisioning, atomicity and hourly scheduling tests passed")
