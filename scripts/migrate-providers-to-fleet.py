#!/usr/bin/env python3
"""Run once per machine after deploying Auth, before upgrading Fleet normally.

Back up standalone providers, publish this account's enabled choices, install
Fleet from this checkout, then replace the old job. Safe to retry after failure.
"""
import ast
import base64
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def load_fleet():
    loader = importlib.machinery.SourceFileLoader("provider_cutover_fleet", str(ROOT/"files/fleet"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    fleet = importlib.util.module_from_spec(spec)
    loader.exec_module(fleet)
    return fleet


def publish_choices(fleet, engine, context):
    for _ in range(2):
        config = fleet._api("GET", "/api/fleet/config")
        if any(f["path"] == "settings/providers.json" for f in config["files"]):
            return
        if Path(engine.CATALOG_PATH).exists() or not Path(engine.REGISTRY_PATH).exists():
            return
        if engine._load_cache().get("_common_auth_context") != context:
            raise RuntimeError("Cannot prove ownership of legacy choices; save your choices in the Auth dashboard first.")
        registry = engine._validate_registry(engine.load_json(engine.REGISTRY_PATH))
        state = engine._load_provider_state()
        if state is None:
            raise ValueError("Cannot read legacy provider state")
        settings = {"version": 2, "enabled": {
            name: state["providers"].get(name, {}).get("enabled", cfg["enabled"])
            for name, cfg in registry["providers"].items() if cfg["provider_type"] == "OpenAICompatible"}}
        if engine.common_auth_context() != context:
            raise RuntimeError("Auth account changed; rerun the migration")
        try:
            fleet._api("POST", "/api/fleet/config/push", {
                "base": config["counter"], "subject": context["subject"], "delete": [],
                "put": [{"path": "settings/providers.json", "executable": False,
                         "content": base64.b64encode((json.dumps(settings, indent=2)+"\n").encode()).decode()}]})
            return
        except fleet.ApiError as exc:
            if exc.status != 409:
                raise
    raise RuntimeError("Auth changed during migration; rerun the script")


def install_payload(fleet):
    targets = (("fleet", fleet.HOME/".local/bin/fleet", ast.parse, 0o755),
               ("fleet-providers.py", fleet.HOME/".local/bin/fleet-providers.py", ast.parse, 0o644),
               ("fleet-manifest.json", fleet.MANIFEST_PATH, json.loads, 0o644),
               ("provider-registry.json", fleet.HOME/".config/fleet/provider-defaults.json", json.loads, 0o644))
    payload = []
    for name, target, validate, mode in targets:
        data = (ROOT/"files"/name).read_bytes()
        validate(data.decode())
        payload.append((target, data, mode))
    for target, data, mode in payload:
        fleet.save_text(target, data, mode)


def legacy_scheduled(fleet):
    if fleet.WINDOWS:
        return False
    if sys.platform == "darwin":
        return (fleet.LAUNCHD_DIR/"com.lost.plus.providers.plist").exists()
    return fleet._systemd_on("providers")


def retire_legacy_job(fleet):
    if fleet.WINDOWS:
        return
    if sys.platform == "darwin":
        import os
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/com.lost.plus.providers"], capture_output=True)
        (fleet.LAUNCHD_DIR/"com.lost.plus.providers.plist").unlink(missing_ok=True)
    elif fleet._systemd_remove("providers"):
        raise RuntimeError("Cannot retire the old provider timer; rerun the script")


def migrate(fleet, run=subprocess.check_call):
    engine = fleet.provider_engine()
    context = engine.common_auth_context()
    engine._validate_registry(fleet._api("GET", "/api/fleet/providers/catalog")["registry"])
    legacy = fleet.HOME/".local/bin/providers"
    setup_state = Path(os.environ.get("STATE_DIR") or fleet.HOME/".local/state/setup")/"script-state.tsv"
    old_job = legacy_scheduled(fleet)
    schedule_on = fleet.schedule_installed() or old_job
    with fleet._fleet_lock(), engine._consumer_sync_lock():
        backup = fleet.FLEET_STATE/"backup/providers-migration"
        for source, name in ((Path(engine.REGISTRY_PATH), "registry.json"),
                             (Path(engine.STATE_PATH), "state.json"), (legacy, "providers"),
                             (setup_state, "script-state.tsv")):
            if source.exists() and not (backup/name).exists():
                backup.mkdir(mode=0o700, parents=True, exist_ok=True)
                shutil.copy2(source, backup/name)
        publish_choices(fleet, engine, context)
        cache = engine._load_cache()
        if cache.get("_common_auth_context") == context and cache.get("_fleet_account") in (None, context):
            cache["_fleet_account"] = context
            engine._save_cache(cache)
    install_payload(fleet)
    command = [sys.executable, str(fleet.HOME/".local/bin/fleet")]
    run(command+["sync", "--pull"])
    if engine.common_auth_context() != context:
        raise RuntimeError("Auth account changed; rerun the migration")
    if schedule_on:
        run(command+["schedule", "enable"])
    if legacy.exists() or old_job:
        retire_legacy_job(fleet)
        legacy.unlink(missing_ok=True)
    # fleet updates itself now, so setup only forgets the old module.
    if setup_state.exists():
        lines = [line for line in setup_state.read_text().splitlines() if line.split("\t", 1)[0] != "providers"]
        fleet.save_text(setup_state, "".join(line + "\n" for line in lines))
    print("Provider migration complete.")


if __name__ == "__main__":
    if sys.argv[1:]:
        raise SystemExit(__doc__)
    fleet = load_fleet()
    try:
        migrate(fleet)
    except (fleet.ApiError, OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"Provider migration stopped: {exc}")
