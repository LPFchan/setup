#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A stand-in auth module: `auth token passage` prints a bearer.
cat > "$TMP/auth" <<'SH'
#!/bin/sh
[ "$1" = token ] && [ "$2" = passage ] && { echo bearer-secret; exit 0; }
exit 1
SH
chmod +x "$TMP/auth"
export AUTH_BIN="$TMP/auth"

python3 - "$ROOT/files/passage" <<'PY'
import contextlib, io, json, os, runpy, sys

m = runpy.run_path(sys.argv[1], run_name="passage_client_test")
calls = []
vault = {("infra", "CF_MASTER_TOKEN"): "cf-secret", ("llm", "KEY"): "llm-secret"}

def fake_call(tool, arguments, token):
    calls.append((tool, arguments, token))
    assert token == "bearer-secret"
    if tool == "get_secret":
        key = (arguments["folder"], arguments["item_name"])
        if key not in vault:
            raise m["PassageError"](f"Item not found: {arguments['item_name']}")
        return vault[key]
    if tool == "list_secrets":
        return json.dumps({"folder": arguments["folder"], "items": [
            {"name": item} for folder, item in sorted(vault) if folder == arguments["folder"]
        ]})
    raise AssertionError(tool)

g = m["cmd_run"].__globals__
g["_vault_call"] = fake_call
execs = []
g["os"].execvpe = lambda file, args, env: execs.append((file, args, env))

# get prints the value; list prints names.
assert m["get_secret"]("infra", "CF_MASTER_TOKEN", m["_bearer"]()) == "cf-secret"
assert m["list_secrets"]("llm", m["_bearer"]()) == ["KEY"]

# run: the vault fills unset names, and an existing value wins.
os.environ.pop("CLOUDFLARE_API_TOKEN", None)
os.environ["ALREADY"] = "from-shell"
m["cmd_run"](["--env", "CLOUDFLARE_API_TOKEN=infra/CF_MASTER_TOKEN",
              "--env", "ALREADY=llm/KEY", "--", "sh", "-c", "true"])
file, args, env = execs[-1]
assert (file, args) == ("sh", ["sh", "-c", "true"])
assert env["CLOUDFLARE_API_TOKEN"] == "cf-secret"
assert env["ALREADY"] == "from-shell"
assert [c[1]["item_name"] for c in calls if c[0] == "get_secret"][-1] == "CF_MASTER_TOKEN"
assert all(c[1].get("item_name") != "KEY" for c in calls if c[0] == "get_secret")

# run: when every name is already set, the vault is never contacted.
before = len(calls)
os.environ["CLOUDFLARE_API_TOKEN"] = "ci-secret"
m["cmd_run"](["--env", "CLOUDFLARE_API_TOKEN=infra/CF_MASTER_TOKEN", "--", "true"])
assert len(calls) == before and execs[-1][2]["CLOUDFLARE_API_TOKEN"] == "ci-secret"
os.environ.pop("CLOUDFLARE_API_TOKEN")

# run: a missing item and malformed arguments fail before exec.
for bad in (["--env", "X=infra/NOPE", "--", "true"],
            ["--env", "X=infra", "--", "true"],
            ["--env", "X=infra/Y", "true"],
            ["--env", "X=infra/Y", "--"]):
    n = len(execs)
    try:
        m["cmd_run"](bad)
    except m["PassageError"]:
        pass
    else:
        raise AssertionError(bad)
    assert len(execs) == n
print("passage client tests passed")
PY
