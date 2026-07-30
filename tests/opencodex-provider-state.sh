#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export PROVIDER_STATE_PATH="$TMP/providers/state.json"
mkdir -p "$(dirname "$PROVIDER_STATE_PATH")"

python3 - "$ROOT/files/opencodex" "$ROOT/files/claudex-profiles.json" <<'PY'
import copy
import json
import runpy
import sys
from pathlib import Path

launcher, registry_path = sys.argv[1:]
namespace = runpy.run_path(launcher, run_name="opencodex_provider_state_test")
globals_ = namespace["enabled_providers"].__globals__
registry = namespace["load_registry"](Path(registry_path))
state_path = Path(globals_["PROVIDER_STATE"])

# Missing state preserves registry defaults during bootstrap.
assert "commandcode" in namespace["enabled_providers"](registry)

state_path.write_text(json.dumps({
    "version": 1,
    "providers": {
        "commandcode": {"enabled": False},
        "codex": {"enabled": False},
        "anthropic": {"enabled": False},
    },
}))
effective = namespace["enabled_providers"](registry)
assert "commandcode" not in effective
assert "codex" in effective and "anthropic" in effective
assert namespace["provider_model_options"](
    "other",
    registry,
    {"commandcode/hidden": {"id": "commandcode/hidden", "efforts": []}},
) == []

# Local status reaches the OpenCodex config, which is what `ocx sync` filters on
# when it rebuilds the Codex model catalog the desktop picker reads.
auth = {"commandcode": {"key": "secret"}}
desired, _ = namespace["desired_opencodex_config"](registry, {}, auth)
assert desired["providers"]["commandcode"]["disabled"] is True
state_path.write_text(json.dumps({
    "version": 1,
    "providers": {"commandcode": {"enabled": True}},
}))
desired, _ = namespace["desired_opencodex_config"](registry, {}, auth)
assert desired["providers"]["commandcode"]["disabled"] is False

# A local enable never resurrects a provider whose key is gone.
desired, _ = namespace["desired_opencodex_config"](registry, {}, {})
assert desired["providers"]["commandcode"]["disabled"] is True

# Explicit local true overrides an OpenAI-compatible registry default.
registry_disabled = copy.deepcopy(registry)
registry_disabled["providers"]["commandcode"]["enabled"] = False
state_path.write_text(json.dumps({
    "version": 1,
    "providers": {"commandcode": {"enabled": True}},
}))
assert "commandcode" in namespace["enabled_providers"](registry_disabled)

# Disabled providers are neither probed nor accepted by direct run.
state_path.write_text(json.dumps({
    "version": 1,
    "providers": {"commandcode": {"enabled": False}},
}))
original_urlopen = namespace["urllib"].request.urlopen
try:
    namespace["urllib"].request.urlopen = lambda *args, **kwargs: (_ for _ in ()).throw(
        AssertionError("disabled provider was probed")
    )
    assert namespace["provider_support_index"](
        registry, {"commandcode": {"key": "secret"}}
    ) == {}
finally:
    namespace["urllib"].request.urlopen = original_urlopen

globals_["load_registry"] = lambda: registry
globals_["sys"].argv = [launcher, "run", "commandcode"]
try:
    namespace["main"]()
except namespace["UserError"] as exc:
    assert "provider is disabled: commandcode" in str(exc)
else:
    raise AssertionError("direct run accepted a disabled provider")

for malformed in (
    [],
    {"version": 99, "providers": {}},
    {"version": 1, "providers": {"commandcode": {"enabled": "no"}}},
):
    state_path.write_text(json.dumps(malformed))
    try:
        namespace["enabled_providers"](registry)
    except namespace["UserError"] as exc:
        assert "provider state" in str(exc)
    else:
        raise AssertionError("malformed provider state was accepted")
PY

echo "opencodex provider-state tests passed"
