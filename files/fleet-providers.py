#!/usr/bin/env python3
# setup-module: fleet
# setup-source: files/fleet-providers.py
"""Fleet's private provider credential and model engine.

The Auth dashboard owns provider management. Fleet reconciles the shared catalog
with account enablement, reads keys from Passage, and maintains credential and
model mirrors for OpenCode, Hermes, Pi and OpenCodex. Its nightly pass refreshes
model inventories and capability snapshots while preserving the proxy process.
"""

import contextlib, datetime, hashlib, json, math, os, pathlib, re, shutil, subprocess, sys, tempfile
import urllib.error, urllib.parse, urllib.request
if sys.platform == "win32":
    import msvcrt
else:
    import fcntl

PROVIDER_STATE_VERSION = 1
STATE_PATH = os.path.expanduser(
    os.environ.get("PROVIDER_STATE_PATH", "~/.config/providers/state.json")
)
CACHE_PATH = os.path.expanduser(
    os.environ.get("PROVIDERS_CACHE_PATH", "~/.config/providers/credentials.json")
)
CAPABILITIES_PATH = os.path.expanduser(
    os.environ.get(
        "PROVIDERS_CAPABILITIES_PATH",
        os.environ.get("PROVIDER_CAPABILITIES_PATH", "~/.config/providers/capabilities.json"),
    )
)
CAPABILITIES_VERSION = 1
_LAST_FETCH_RAW = None
_LAST_FETCH_ENDPOINT = None
REGISTRY_PATH = os.environ.get(
    "PROVIDERS_REGISTRY",
    os.path.expanduser("~/.config/providers/registry.json"),
)
SETTINGS_PATH = os.path.expanduser("~/.agents/settings/providers.json")
DEFAULTS_PATH = str(pathlib.Path(__file__).with_name("provider-registry.json"))
CATALOG_PATH = os.path.expanduser("~/.config/providers/catalog.json")
OPENCODEX_BIN = os.environ.get(
    "OPENCODEX_LAUNCHER", os.path.expanduser("~/.local/bin/opencodex")
)
AUTH_BIN = os.environ.get("FLEET_AUTH_BIN", os.environ.get("AUTH_BIN", os.path.expanduser("~/.local/bin/auth")))
CONSUMER_SYNC_LOCK = os.path.expanduser("~/.config/auth/consumer-sync.lock")
_SYNC_LOCK_DEPTH = 0
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
OPENCODE_PATH = os.path.expanduser("~/.config/opencode/opencode.json")
HERMES_CONFIG = os.path.expanduser(
    os.environ.get("HERMES_CONFIG", "~/.hermes/config.yaml")
)
PI_MODELS_PATH = os.path.expanduser(
    os.environ.get("PI_MODELS_PATH", "~/.pi/agent/models.json")
)
ZSENV_PATH = os.path.expanduser("~/.zshenv")
SERVICE_DIR = os.path.expanduser("~/.config/systemd/user")
OLD_AUTH_PATH = os.path.expanduser("~/.local/share/opencode/auth.json")
# canonical vault store (folder + item-name convention)
VAULT_FOLDER = "llm"
VAULT_URL = os.environ.get("PASSAGE_MCP_URL", "https://passage.lost.plus/mcp")
VAULT_TOKEN = os.environ.get("PASSAGE_MCP_TOKEN", "")

AUTH_BLOCK_BEGIN = "# BEGIN setup:api-keys"
AUTH_BLOCK_END = "# END setup:api-keys"

def load_json(path):
    with open(path) as f:
        return json.load(f)


def load_json_or_quarantine(path):
    """Read JSON, setting a corrupt file aside so the next write can recover.

    An interrupted write can leave a truncated file behind. Without this the
    read fails on every subsequent run and the tool can never repair itself.
    """
    if not os.path.exists(path):
        return {}
    try:
        return load_json(path)
    except json.JSONDecodeError as exc:
        quarantined = path + ".corrupt"
        os.replace(path, quarantined)
        print(
            f"  {os.path.basename(path)} was corrupt ({exc}); "
            f"moved to {quarantined} and rebuilding",
            file=sys.stderr,
        )
        return {}


def save_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def save_json_atomic(path, data, mode=None):
    directory = os.path.dirname(path)
    pathlib.Path(directory).mkdir(parents=True, exist_ok=True)
    try:
        mode = os.stat(path).st_mode & 0o777 if mode is None else mode
    except FileNotFoundError:
        mode = 0o600 if mode is None else mode
    fd, tmp_name = tempfile.mkstemp(prefix=".providers.", dir=directory)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def _env_name(provider):
    return f"{provider.replace('-', '_').upper()}_API_KEY"


def _oauth_env_name(provider):
    return f"{provider.replace('-', '_').upper()}_OAUTH_TOKEN"


def _provider_from_env(env_name):
    if env_name.endswith("_API_KEY"):
        return env_name[:-8].lower().replace("_", "-")
    if env_name.endswith("_OAUTH_TOKEN"):
        return env_name[:-12].lower().replace("_", "-")
    return ""


# --- vault transport ---------------------------------------------------


class VaultError(RuntimeError):
    pass


class CommonAuthError(RuntimeError):
    def __init__(self, message, authoritative=False):
        super().__init__(message)
        self.authoritative = authoritative


class CommonAuthContextChanged(CommonAuthError):
    pass


@contextlib.contextmanager
def _consumer_sync_lock():
    global _SYNC_LOCK_DEPTH
    if _SYNC_LOCK_DEPTH:
        _SYNC_LOCK_DEPTH += 1
        try:
            yield
        finally:
            _SYNC_LOCK_DEPTH -= 1
        return
    pathlib.Path(CONSUMER_SYNC_LOCK).parent.mkdir(parents=True, exist_ok=True)
    with open(CONSUMER_SYNC_LOCK, "a+") as handle:
        os.chmod(CONSUMER_SYNC_LOCK, 0o600)
        if sys.platform == "win32":
            if not handle.tell():
                handle.write(" "); handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
        else:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        _SYNC_LOCK_DEPTH = 1
        try:
            yield
        finally:
            _SYNC_LOCK_DEPTH = 0
            if sys.platform == "win32":
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _auth_command(*args):
    return ([sys.executable, "-X", "utf8", AUTH_BIN] if sys.platform == "win32" else [AUTH_BIN]) + list(args)


def common_auth_token(scope, context=None):
    """Resolve one lost.plus service credential through the auth module."""
    if not os.access(AUTH_BIN, os.X_OK):
        raise CommonAuthError(f"auth module not installed at {AUTH_BIN}; run: setup install auth")
    try:
        command = _auth_command("token", scope)
        if context is not None:
            command.extend([
                "--expect-context",
                json.dumps(context, sort_keys=True, separators=(",", ":")),
            ])
        result = subprocess.run(command, capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired as exc:
        raise CommonAuthError(f"{scope}: credential refresh timed out") from exc
    token = result.stdout.strip()
    if result.returncode == 5:
        raise CommonAuthContextChanged(f"{scope}: setup login changed during sync")
    if result.returncode or not token:
        detail = result.stderr.strip() or "credential unavailable"
        raise CommonAuthError(
            f"{scope}: {detail}", authoritative=result.returncode in (3, 4)
        )
    return token


def common_auth_context():
    """Return the non-secret Auth origin/account binding for managed copies."""
    if not os.access(AUTH_BIN, os.X_OK):
        raise CommonAuthError(f"auth module not installed at {AUTH_BIN}; run: setup install auth")
    try:
        result = subprocess.run(
            _auth_command("context"), capture_output=True, text=True, timeout=10
        )
    except subprocess.TimeoutExpired as exc:
        raise CommonAuthError("Auth context lookup timed out") from exc
    if result.returncode:
        raise CommonAuthError(result.stderr.strip() or "Auth context unavailable")
    try:
        context = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise CommonAuthError("Auth returned an invalid account context") from exc
    if (
        not isinstance(context, dict)
        or not isinstance(context.get("origin"), str)
        or not context["origin"]
        or not isinstance(context.get("subject"), str)
        or not context["subject"]
    ):
        raise CommonAuthError("Auth returned an invalid account context")
    return {"origin": context["origin"], "subject": context["subject"]}


def _sync_common_auth(servers):
    with _consumer_sync_lock():
        for attempt in range(2):
            try:
                return _sync_common_auth_once(servers)
            except CommonAuthContextChanged:
                if attempt:
                    print("  Common Auth login kept changing; sync deferred", file=sys.stderr)
                    return


def _sync_common_auth_once(servers):
    """Refresh Common Auth entries without deleting the last good local copy."""
    global VAULT_TOKEN
    managed = {
        auth.get("provider", name)
        for name, cfg in servers.items()
        for auth in [cfg.get("auth", {})]
        if auth.get("type") == "common_auth"
    }
    # A process environment has no account binding and may come from a shell
    # opened before the current Auth login. Only reconciled disk stores may be
    # used as Common Auth fallbacks.
    for provider in managed:
        os.environ.pop(_env_name(provider), None)
    os.environ.pop("PASSAGE_MCP_TOKEN", None)
    VAULT_TOKEN = ""
    rejected = set()
    try:
        context = common_auth_context()
    except CommonAuthError as exc:
        print(f"  Common Auth context unavailable ({exc}); keeping bound credentials", file=sys.stderr)
        # A token fetched without a context could belong to a login that
        # changed while context lookup was blocked or timing out. Preserve the
        # account-bound cache, but do not perform any Auth or vault reads.
        return
    cache = _load_cache()
    if cache.get("_fleet_account") is not None and cache["_fleet_account"] != context:
        raise CommonAuthContextChanged("account changed during provider sync")
    previous_context = cache.get("_common_auth_context")
    context_changed = context is not None and previous_context != context
    if context_changed:
        for provider in managed:
            cache.pop(provider, None)
            os.environ.pop(_env_name(provider), None)
        cache.pop("_vault_token", None)
        VAULT_TOKEN = ""
        os.environ.pop("PASSAGE_MCP_TOKEN", None)
        rejected.update(managed)
        _save_cache(cache)
        _sync_mirrors(managed_absent=managed)
        _sync_hermes_mirror(servers, {}, authoritative_missing=managed)
        cache["_common_auth_context"] = context
        _save_cache(cache)
    authoritative_removed = False
    try:
        VAULT_TOKEN = common_auth_token("passage", context)
        cache_remove("_vault_token")
    except CommonAuthContextChanged:
        raise
    except CommonAuthError as exc:
        if exc.authoritative:
            VAULT_TOKEN = ""
            os.environ.pop("PASSAGE_MCP_TOKEN", None)
            cache.pop("_vault_token", None)
            third_party = {p for p in cache if not p.startswith("_") and p not in managed}
            for provider in third_party:
                cache.pop(provider, None)
                os.environ.pop(_env_name(provider), None)
            rejected.update(third_party)
            _save_cache(cache)
            authoritative_removed = True
        elif not VAULT_TOKEN:
            print(f"  Common Auth unavailable ({exc}); vault sync skipped", file=sys.stderr)
    for name, cfg in servers.items():
        auth = cfg.get("auth", {})
        if auth.get("type") != "common_auth":
            continue
        try:
            provider = auth.get("provider", name)
            cache_set(provider, common_auth_token(auth["scope"], context))
            rejected.discard(provider)
        except CommonAuthContextChanged:
            raise
        except CommonAuthError as exc:
            if exc.authoritative:
                provider = auth.get("provider", name)
                cache_remove(provider)
                os.environ.pop(_env_name(provider), None)
                rejected.add(provider)
                authoritative_removed = True
                print(f"  Common Auth removed {name} credential ({exc})", file=sys.stderr)
            else:
                print(f"  Common Auth unavailable ({exc}); keeping cached {name} credential", file=sys.stderr)
    if context_changed or authoritative_removed or rejected:
        _sync_mirrors(managed_absent=rejected)
        _sync_hermes_mirror(servers, {}, authoritative_missing=rejected)


def vault_available():
    return bool(VAULT_TOKEN)


def _vault_call(tool, arguments):
    """Call a passage MCP tool over direct HTTP. Raises VaultError on
    transport/protocol failure; returns the tool's text payload on success."""
    if not VAULT_TOKEN:
        raise VaultError("vault token not set (PASSAGE_MCP_TOKEN)")
    body = {
        "jsonrpc": "2.0",
        "id": id(arguments),
        "method": "tools/call",
        "params": {"name": tool, "arguments": arguments},
    }
    req = urllib.request.Request(
        VAULT_URL,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {VAULT_TOKEN}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            # The vault proxy 403s Python's default UA (like Cloudflare edges).
            "User-Agent": "providers/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            payload = json.loads(resp.read())
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise VaultError(f"vault unreachable: {exc}") from exc
    result = payload.get("result", {})
    if result.get("isError"):
        text = ""
        for content in result.get("content", []):
            if content.get("type") == "text":
                text += content.get("text", "")
        raise VaultError(text or f"{tool} failed")
    text = ""
    for content in result.get("content", []):
        if content.get("type") == "text":
            text += content.get("text", "")
    # An empty list comes back with no content blocks at all; only the
    # structured copy carries it.
    if not text and isinstance(result.get("structuredContent"), dict) and "result" in result["structuredContent"]:
        text = json.dumps(result["structuredContent"]["result"])
    return text


def vault_list_items():
    text = _vault_call("list_secrets", {"folder": VAULT_FOLDER})
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        data = {}
    if isinstance(data, list):
        items = [i for group in data if isinstance(group, dict) and group.get("folder") == VAULT_FOLDER
                 for i in group.get("items", [])]
    else:
        items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        raise VaultError("vault list_secrets returned an unexpected shape")
    return [item for item in items if isinstance(item, dict) and item.get("name")]


def vault_get(item_name):
    text = _vault_call("get_secret", {"folder": VAULT_FOLDER, "item_name": item_name})
    if not text:
        return None
    try:
        structured = json.loads(text)
        if isinstance(structured, dict) and "result" in structured:
            return structured["result"]
    except json.JSONDecodeError:
        pass
    return text


# --- local cache (offline source of truth) ------------------------------


def _load_cache():
    if not os.path.exists(CACHE_PATH):
        return {}
    try:
        data = load_json(CACHE_PATH)
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _save_cache(data):
    save_json_atomic(CACHE_PATH, data, mode=0o600)


def _load_capabilities():
    """Load the last-known-good provider capability snapshot.

    Capability data is host state, not setup input.  A broken or incompatible
    snapshot is quarantined and treated as empty so a later refresh can repair
    it; a failed refresh never calls this writer with an empty replacement.
    """
    if not os.path.exists(CAPABILITIES_PATH):
        return {"version": CAPABILITIES_VERSION, "providers": {}}
    try:
        data = load_json(CAPABILITIES_PATH)
    except (OSError, json.JSONDecodeError) as exc:
        quarantined = CAPABILITIES_PATH + ".corrupt"
        try:
            os.replace(CAPABILITIES_PATH, quarantined)
        except OSError:
            pass
        print(f"  capability cache unreadable ({exc}); using empty snapshot", file=sys.stderr)
        return {"version": CAPABILITIES_VERSION, "providers": {}}
    if not _valid_capability_cache(data):
        quarantined = CAPABILITIES_PATH + ".corrupt"
        try:
            os.replace(CAPABILITIES_PATH, quarantined)
        except OSError:
            pass
        print("  capability cache has an unsupported shape; using empty snapshot", file=sys.stderr)
        return {"version": CAPABILITIES_VERSION, "providers": {}}
    return data


def _save_capabilities(data):
    if not _valid_capability_cache(data):
        raise ValueError("invalid capability cache")
    save_json_atomic(CAPABILITIES_PATH, data, mode=0o600)


def _valid_capability_cache(data):
    """Validate cache containers and provenance identity before exposing them."""
    if (
        not isinstance(data, dict)
        or data.get("version") != CAPABILITIES_VERSION
        or not isinstance(data.get("providers"), dict)
    ):
        return False
    digest = re.compile(r"^[0-9a-f]{64}$")
    for name, snapshot in data["providers"].items():
        if not isinstance(name, str) or not NAME_RE.fullmatch(name) or not isinstance(snapshot, dict):
            return False
        if snapshot.get("provider") != name:
            return False
        if (
            not isinstance(snapshot.get("source_endpoint"), str)
            or not isinstance(snapshot.get("fetched_at"), str)
            or not isinstance(snapshot.get("raw_response_sha256"), str)
            or not digest.fullmatch(snapshot["raw_response_sha256"])
            or not isinstance(snapshot.get("evidence_source"), str)
            or not isinstance(snapshot.get("models"), dict)
            or not snapshot["models"]
        ):
            return False
        try:
            parsed = urllib.parse.urlsplit(snapshot["source_endpoint"])
        except ValueError:
            return False
        if parsed.username is not None or parsed.password is not None:
            return False
        for model_id, record in snapshot["models"].items():
            if (
                not isinstance(model_id, str)
                or not model_id
                or not isinstance(record, dict)
                or record.get("provider") != name
                or record.get("id") != model_id
                or record.get("source_endpoint") != snapshot["source_endpoint"]
                or record.get("fetched_at") != snapshot["fetched_at"]
                or record.get("raw_response_sha256") != snapshot["raw_response_sha256"]
                or not isinstance(record.get("metadata_fingerprint"), str)
                or not digest.fullmatch(record["metadata_fingerprint"])
            ):
                return False
    return True


def _unknown_modalities():
    return {"state": "unknown", "values": []}


def _known_modalities(values):
    return {"state": "known", "values": sorted(set(values))}


def _unknown_reasoning():
    return {
        "support": "unknown",
        "supported_efforts": [],
        "default_effort": None,
        "default_enabled": None,
        "mandatory": None,
    }


def _normalize_string_list(value, field):
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise ValueError(f"{field} must be a list of non-empty strings")
    if len(value) != len(set(value)):
        raise ValueError(f"{field} must not contain duplicate values")
    return sorted(value)


def _normalize_exact_string_list(value, field):
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise ValueError(f"{field} must be a list of non-empty strings")
    if len(value) != len(set(value)):
        raise ValueError(f"{field} must not contain duplicate values")
    return list(value)


def _numeric(value, field="number", integer=False):
    """Normalize provider scalar metadata to a JSON number or null."""
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValueError(f"{field} must be numeric or null")
    if isinstance(value, str):
        try:
            value = float(value.strip())
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{field} must be numeric or null") from exc
    if not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{field} must be numeric or null")
    if integer:
        if isinstance(value, float) and not value.is_integer():
            raise ValueError(f"{field} must be an integer or null")
        return int(value)
    return value


def _numeric_int(value, field="number"):
    return _numeric(value, field, integer=True)


def _model_output_limit(row, default=None):
    """Read OpenAI-compatible completion limits, including OpenRouter's nesting."""
    output = row.get("max_completion_tokens", row.get("output"))
    top_provider = row.get("top_provider")
    if output is None and isinstance(top_provider, dict):
        output = top_provider.get("max_completion_tokens")
    return default if output is None else output


def _reasoning_from_row(row):
    """Normalize provider-specific reasoning advertisements without guessing.

    The returned state is one of full (named levels), partial (reasoning is
    supported but no levels were advertised), none (explicitly unsupported),
    or unknown (missing/malformed metadata).  A provider's native labels are
    kept verbatim; they are not mapped to a generic ladder.
    """
    reasoning = row.get("reasoning", None)
    fields = {}
    errors = []
    bool_flags = []
    if reasoning is not None:
        if isinstance(reasoning, bool):
            bool_flags.append(reasoning)
            reasoning = None
        elif not isinstance(reasoning, dict):
            errors.append("reasoning must be an object or boolean")
        else:
            fields = reasoning
    levels = None
    for source, value in (
        ("reasoning.supported_efforts", fields.get("supported_efforts")),
        ("supported_reasoning_levels", row.get("supported_reasoning_levels")),
        ("think_efforts.values", (row.get("think_efforts") or {}).get("values") if isinstance(row.get("think_efforts"), dict) else None),
        # Kimi spells the same list valid_efforts. Both are read rather than
        # one being normalized into the other: a provider's own labels are
        # evidence, and guessing which spelling it "meant" is how a ladder
        # silently goes missing -- k3-256k advertises low/high/max, and with
        # only the `values` spelling matched it read as no levels at all.
        ("think_efforts.valid_efforts", (row.get("think_efforts") or {}).get("valid_efforts") if isinstance(row.get("think_efforts"), dict) else None),
    ):
        if value is None:
            continue
        if source == "supported_reasoning_levels" and isinstance(value, list) and value and all(isinstance(item, dict) for item in value):
            continue
        try:
            candidate = _normalize_exact_string_list(value, source)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        if levels is None:
            levels = candidate
        elif candidate != levels:
            errors.append("conflicting reasoning effort advertisements")

    # Existing provider shapes sometimes wrap levels as {effort: label}.
    raw_levels = row.get("supported_reasoning_levels")
    if raw_levels is not None and isinstance(raw_levels, list) and raw_levels and all(isinstance(item, dict) for item in raw_levels):
        try:
            levels = _normalize_exact_string_list([item["effort"] for item in raw_levels], "supported_reasoning_levels")
        except (KeyError, ValueError) as exc:
            errors.append(f"supported_reasoning_levels: {exc}")

    think = row.get("think_efforts")
    think_default = None
    if think is not None and not isinstance(think, dict):
        errors.append("think_efforts must be an object")
    elif isinstance(think, dict) and think.get("default_effort") is not None:
        if isinstance(think["default_effort"], str) and think["default_effort"]:
            think_default = think["default_effort"]
        else:
            errors.append("think_efforts.default_effort must be a non-empty string")

    for key in ("reasoning_effort", "custom_reasoning", "supports_reasoning"):
        if key in row:
            if not isinstance(row[key], bool):
                errors.append(f"{key} must be boolean")
            else:
                bool_flags.append(row[key])
    if "supported" in fields and not isinstance(fields["supported"], bool):
        errors.append("reasoning.supported must be boolean")
    for key in ("mandatory", "default_enabled"):
        if key in fields and not isinstance(fields[key], bool):
            errors.append(f"reasoning.{key} must be boolean")
    for key in ("default_effort",):
        if key in fields and fields[key] is not None and (not isinstance(fields[key], str) or not fields[key]):
            errors.append("reasoning.default_effort must be a non-empty string or null")
    if errors:
        result = _unknown_reasoning()
        result["errors"] = errors
        return result

    if levels:
        support = "full"
    elif any(bool_flags):
        support = "partial"
    elif bool_flags and not any(bool_flags):
        support = "none"
    elif reasoning is not None:
        # An empty object says nothing about support.  Only an explicit false
        # advertisement is authoritative for the unsupported state.
        if "supported" in fields:
            support = "partial" if fields["supported"] else "none"
        elif any(key in fields for key in ("mandatory", "default_enabled", "default_effort", "supported_efforts")):
            support = "partial"
        else:
            support = "unknown"
    else:
        support = "unknown"
    result = {
        "support": support,
        "supported_efforts": levels or [],
        "default_effort": fields.get("default_effort") if fields.get("default_effort") is not None else think_default,
        "default_enabled": fields.get("default_enabled"),
        "mandatory": fields.get("mandatory"),
    }
    if support == "none" and result["default_effort"] is not None:
        result["support"] = "partial"
    return result


def normalize_model_row(provider, model_id, row, endpoint, fetched_at, response_sha256, static=False):
    """Return one credential-free normalized capability record.

    Inventory metadata remains useful even if a capability field is malformed;
    only that capability section becomes unknown and records its error.
    """
    if not isinstance(row, dict):
        raise ValueError("model row must be an object")
    errors = []
    architecture = row.get("architecture")
    if architecture is not None and not isinstance(architecture, dict):
        errors.append("architecture must be an object")
    raw_modalities = row.get("input_modalities")
    if raw_modalities is None and isinstance(architecture, dict):
        raw_modalities = architecture.get("input_modalities")
    if raw_modalities is None:
        modalities = _unknown_modalities()
    else:
        try:
            modalities = _known_modalities(_normalize_string_list(raw_modalities, "input_modalities"))
        except ValueError as exc:
            modalities = _unknown_modalities()
            modalities["error"] = str(exc)
            errors.append(str(exc))

    parameters = row.get("supported_parameters")
    if "supported_parameters" in row and parameters is None:
        parameters_value = {"state": "unknown", "values": [], "error": "supported_parameters must be a list of strings"}
        errors.append("supported_parameters must be a list of strings")
    elif parameters is None:
        parameters_value = {"state": "unknown", "values": []}
    else:
        try:
            parameters_value = {"state": "known", "values": _normalize_string_list(parameters, "supported_parameters")}
        except ValueError as exc:
            parameters_value = {"state": "unknown", "values": [], "error": str(exc)}
            errors.append(str(exc))

    reasoning_value = _reasoning_from_row(row)
    if reasoning_value.get("errors"):
        errors.extend(reasoning_value["errors"])
    context = row.get("context_length", row.get("context"))
    output = _model_output_limit(row)
    pricing = row.get("pricing", row.get("cost", {}))
    if not isinstance(pricing, dict):
        pricing = {}
        errors.append("pricing/cost must be an object")
    try:
        context_value = _numeric_int(context, "context")
    except ValueError as exc:
        context_value = None
        errors.append(str(exc))
    try:
        output_value = _numeric_int(output, "output")
    except ValueError as exc:
        output_value = None
        errors.append(str(exc))
    cost_values = {}
    for key, raw_value in (
        ("input", pricing.get("prompt", pricing.get("input"))),
        ("output", pricing.get("completion", pricing.get("output"))),
        ("cache_read", pricing.get("cache_prompt", pricing.get("cache_read"))),
    ):
        try:
            cost_values[key] = _numeric(raw_value, f"cost.{key}")
            # The shared capability contract follows OpenRouter and stores
            # USD per token. Grimoire advertises USD per million tokens.
            if provider == "grimoire" and cost_values[key] is not None:
                cost_values[key] /= 1_000_000
        except ValueError as exc:
            cost_values[key] = None
            errors.append(str(exc))
    record = {
        "provider": provider,
        "id": model_id,
        "input_modalities": modalities,
        "supported_parameters": parameters_value,
        "reasoning": reasoning_value,
        "context": context_value,
        "output": output_value,
        "cost": cost_values,
        "source_endpoint": endpoint,
        "fetched_at": fetched_at,
        "raw_response_sha256": response_sha256,
        "evidence_source": "provider_models_endpoint" if not static else "provider_registry_static_models",
    }
    if errors:
        record["capability_errors"] = sorted(set(errors))
    relevant = {
        key: record[key]
        for key in ("provider", "id", "input_modalities", "supported_parameters", "reasoning", "context", "output", "cost")
    }
    record["metadata_fingerprint"] = hashlib.sha256(
        json.dumps(relevant, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    ).hexdigest()
    return record


def _response_rows(payload):
    if not isinstance(payload, dict):
        raise ValueError("models response must be an object")
    rows = payload.get("data", payload.get("models"))
    if not isinstance(rows, list):
        raise ValueError("models response must contain a data/models list")
    return rows


def _credential_free_endpoint(base_url):
    """Return the /models endpoint without userinfo, query, or fragment."""
    parsed = urllib.parse.urlsplit(str(base_url))
    host = parsed.hostname or ""
    try:
        port = parsed.port
    except ValueError:
        port = None
    if port is not None:
        host = f"{host}:{port}"
    path = parsed.path.rstrip("/") + "/models"
    return urllib.parse.urlunsplit((parsed.scheme, host, path, "", ""))


def _capability_snapshot(provider, cfg, payload=None, rows=None, static=False, raw_bytes=None):
    endpoint = _credential_free_endpoint(cfg["baseURL"])
    fetched_at = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    if rows is None and payload is not None:
        rows = _response_rows(payload)
    rows = rows or []
    if raw_bytes is not None:
        raw = raw_bytes
    elif payload is not None:
        raw = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    else:
        raw = json.dumps(rows, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    response_sha256 = hashlib.sha256(raw).hexdigest()
    normalized = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"]:
            continue
        normalized[row["id"]] = normalize_model_row(
            provider, row["id"], row, endpoint, fetched_at, response_sha256, static=static
        )
    return {
        "provider": provider,
        "source_endpoint": endpoint,
        "fetched_at": fetched_at,
        "raw_response_sha256": response_sha256,
        "evidence_source": "provider_models_endpoint" if not static else "provider_registry_static_models",
        "models": normalized,
    }


def _update_capability_cache(provider, snapshot):
    if not isinstance(snapshot, dict) or not snapshot.get("models"):
        return False
    cache = _load_capabilities()
    cache.setdefault("providers", {})[provider] = snapshot
    _save_capabilities(cache)
    return True


def cache_get(provider):
    return _load_cache().get(provider, "")


def cache_set(provider, key):
    with _consumer_sync_lock():
        data = _load_cache()
        data[provider] = key
        _save_cache(data)


def cache_remove(provider):
    with _consumer_sync_lock():
        data = _load_cache()
        if provider in data:
            del data[provider]
            _save_cache(data)


def _sync_cache_from_vault(servers):
    with _consumer_sync_lock():
        return _sync_cache_from_vault_once(servers)


def _sync_cache_from_vault_once(servers):
    """Pull the whole vault llm/ folder into the local cache, not just the
    registry-listed servers: the vault is canonical, so every conforming
    {PROVIDER}_API_KEY item becomes a cached provider (the 4 extra live
    providers, e.g. alibaba/ollama-cloud, are enrolled in vault but absent
    from the canonical provider registry).
    Network-optional: on vault unreachable, keep the cache and note it."""
    if not vault_available():
        print("  vault token unset; using local cache", file=sys.stderr)
        return True
    try:
        items = {item["name"]: item for item in vault_list_items()}
    except VaultError as exc:
        print(f"  vault unreachable ({exc}); using local cache", file=sys.stderr)
        return True
    common_auth_providers = {
        _auth_provider(name, cfg)
        for name, cfg in servers.items()
        if cfg.get("auth", {}).get("type") == "common_auth"
    }
    retired = set(_load_retired())
    cache = _load_cache()
    changed = False
    for env_name, item in items.items():
        if item.get("deleted"):
            continue
        if not env_name.endswith("_API_KEY"):
            continue
        provider = _provider_from_env(env_name)
        if not provider:
            continue
        if provider in common_auth_providers:
            continue
        # Pulling the whole folder is deliberate -- providers live in the vault
        # that the registry never lists. A retired name is the one exception:
        # the item outlives the registry entry, so without this the vault hands
        # the dead key straight back to the cache the sweep just cleared.
        if provider in retired:
            continue
        value = vault_get(env_name)
        if value is None:
            continue
        if cache.get(provider) != value:
            cache[provider] = value
            changed = True
    listed = {_provider_from_env(i["name"]) for i in items.values() if not i.get("deleted") and _conforming_item_name(i.get("name", ""))}
    removed = {name for name in cache if not name.startswith("_") and name not in common_auth_providers and name not in listed}
    for name in removed:
        cache.pop(name, None)
    if changed or removed:
        _save_cache(cache)
    if removed:
        _sync_mirrors(managed_absent=removed)
        _sync_hermes_mirror(servers, {}, authoritative_missing=removed)
    return True


# --- .zshenv api-keys block --------------------------------------------


def _read_env_block():
    if not os.path.exists(ZSENV_PATH):
        return {}
    keys = {}
    in_block = False
    with open(ZSENV_PATH) as f:
        for line in f:
            if line.strip() == AUTH_BLOCK_BEGIN:
                in_block = True
                continue
            if line.strip() == AUTH_BLOCK_END:
                in_block = False
                continue
            if in_block:
                line = line.strip()
                if line.startswith("export ") and "=" in line:
                    kv = line[len("export "):]
                    name, _, val = kv.partition("=")
                    keys[name] = val
    return keys


def _write_env_block(lines):
    ensure_block = False
    existing = []
    if os.path.exists(ZSENV_PATH):
        in_block = False
        with open(ZSENV_PATH) as f:
            for line in f:
                stripped = line.strip()
                if stripped == AUTH_BLOCK_BEGIN:
                    in_block = True
                    continue
                if stripped == AUTH_BLOCK_END:
                    in_block = False
                    continue
                if not in_block:
                    existing.append(line)
                # drop old block lines
        ensure_block = True
    else:
        ensure_block = True

    # The separator below is written fresh each time, so the blank line that
    # preceded the old block has to go with it. Keeping it grew the file by one
    # blank line per write -- 180 of them had piled up before this was caught.
    while existing and not existing[-1].strip():
        existing.pop()

    with open(ZSENV_PATH, "w") as f:
        for line in existing:
            f.write(line)
        if ensure_block:
            f.write(f"\n{AUTH_BLOCK_BEGIN}\n")
            for l in lines:
                f.write(l + "\n")
            f.write(f"{AUTH_BLOCK_END}\n")


def _sync_zsenv_to_cache(servers=None):
    with _consumer_sync_lock():
        return _sync_zsenv_to_cache_once(servers)


def _sync_zsenv_to_cache_once(servers=None):
    """Ensure the local cache reflects the .zshenv api-keys block.
    Never deletes entries that exist only in the cache."""
    block = _read_env_block()
    if not block:
        return
    cache = _load_cache()
    common_auth_providers = {
        auth.get("provider", name)
        for name, cfg in (servers or {}).items()
        for auth in [cfg.get("auth", {})]
        if auth.get("type") == "common_auth"
    }
    retired = set(_load_retired())
    changed = False
    for env_name, value in block.items():
        provider = _provider_from_env(env_name)
        if not provider or provider in common_auth_providers:
            continue
        # Keep the invariant that a retired name never enters the cache. The
        # sweep runs after this read and would clear it anyway, but an
        # interrupted refresh -- a dozen vault fetches happen in between -- would
        # otherwise leave the dead key in the cache on disk, and the next bare
        # `providers` call re-mirrors it. Enforcing it at both cache entry points
        # also means a later reordering of the refresh cannot quietly break this.
        if provider in retired:
            continue
        if env_name.endswith("_API_KEY"):
            if cache.get(provider) != value:
                cache[provider] = value
                changed = True
    if changed:
        _save_cache(cache)


def _write_auth_mirror(cache, managed_absent=None):
    """Write opencode's native auth.json from the cache (api-type entries only).

    Mirrors only fleet providers that appear in the cache; never deletes OAuth or
    unrelated entries that exist only in auth.json.
    """
    existing = {}
    if os.path.exists(OLD_AUTH_PATH):
        try:
            existing = load_json(OLD_AUTH_PATH)
        except Exception:
            existing = {}
    if not isinstance(existing, dict):
        existing = {}
    for provider in managed_absent or ():
        entry = existing.get(provider)
        if isinstance(entry, dict) and entry.get("type") == "api":
            del existing[provider]
    for provider, value in cache.items():
        if not value or provider.startswith("_"):
            continue
        entry = existing.get(provider)
        if isinstance(entry, dict) and entry.get("type") == "oauth":
            continue
        if provider not in existing or existing.get(provider, {}).get("key") != value:
            existing[provider] = {"type": "api", "key": value}
    pathlib.Path(os.path.dirname(OLD_AUTH_PATH)).mkdir(parents=True, exist_ok=True)
    save_json_atomic(OLD_AUTH_PATH, existing, mode=0o600)


def _write_env_mirror(cache):
    """Write the .zshenv api-keys block from the cache, preserving OAuth
    token lines from auth.json.

    api-type fleet providers come from the cache (vault-authoritative); OAuth tokens
    (*_OAUTH_TOKEN) are owned by their harnesses and carried through from
    auth.json unchanged, never written from the cache.
    """
    lines = [f"export {_env_name(p)}={v}" for p, v in sorted(cache.items())
             if v and not p.startswith("_")]
    if os.path.exists(OLD_AUTH_PATH):
        try:
            auth = load_json(OLD_AUTH_PATH)
        except Exception:
            auth = {}
        if isinstance(auth, dict):
            for provider, entry in sorted(auth.items()):
                if isinstance(entry, dict) and entry.get("type") == "oauth":
                    access = entry.get("access", "")
                    if access:
                        lines.append(f"export {_oauth_env_name(provider)}={access}")
    if sys.platform != "win32":
        _write_env_block(lines)


def _sync_mirrors(managed_absent=None):
    """cache -> opencode auth.json + .zshenv. Both mirrors are one-way;
    the cache (from vault) is authoritative for api keys."""
    with _consumer_sync_lock():
        cache = _load_cache()
        _write_auth_mirror(cache, managed_absent)
        _write_env_mirror(cache)


def _hermes_models(refreshed_models):
    """Model ids from the refreshed list, kept stable by position (no
    cross-run reordering of the unchanged tail)."""
    ids = list(refreshed_models.keys())
    return [value for value in ids if value] or None


def _sync_hermes_credentials_without_yaml(servers, authoritative_missing=None):
    """Update managed Hermes credentials without needing a YAML package.

    This deliberately touches only simple top-level custom_providers list
    entries and their api_key field. Unknown structure is left unchanged,
    except that a matched rejected credential is always stripped.
    """
    if not os.path.exists(HERMES_CONFIG):
        return
    try:
        lines = pathlib.Path(HERMES_CONFIG).read_text().splitlines(keepends=True)
    except OSError:
        return
    missing = authoritative_missing or set()
    managed = {name: cfg for name, cfg in servers.items()}
    spans = []
    in_custom = False
    item_indent = None
    current_start = None
    for index, line in enumerate(lines):
        if re.match(r"^custom_providers:\s*(?:#.*)?$", line.rstrip("\r\n")):
            in_custom = True
            continue
        if (in_custom and line and not line[0].isspace()
                and not line.startswith("-") and not line.lstrip().startswith("#")):
            if current_start is not None:
                spans.append((current_start, item_indent, index))
                current_start = None
            break
        if not in_custom:
            continue
        match = re.match(r"^(\s*)-\s+", line)
        if not match:
            continue
        if item_indent is None:
            item_indent = match.group(1)
        if match.group(1) != item_indent:
            continue
        if current_start is not None:
            spans.append((current_start, item_indent, index))
        current_start = index
    else:
        if current_start is not None:
            spans.append((current_start, item_indent, len(lines)))

    changed = False
    for start, indent, end in reversed(spans):
        name = None
        for index in range(start, end):
            prefix = r"^" + re.escape(indent)
            field = re.match(
                prefix + (r"-\s*" if index == start else r"\s+")
                + r"name\s*:\s*([^#\r\n]+?)\s*(?:#.*)?(?:\r?\n)?$",
                lines[index],
            )
            if field:
                name = field.group(1).strip()
                if len(name) >= 2 and name[0] == name[-1] and name[0] in "\"'":
                    name = name[1:-1]
                break
        cfg = managed.get(name)
        if cfg is None:
            continue
        auth_provider = _auth_provider(name, cfg)
        key_indexes = [
            index for index in range(start, end)
            if re.match(
                r"^" + re.escape(indent)
                + (r"-\s*" if index == start else r"\s+") + r"api_key\s*:",
                lines[index],
            )
        ]
        if auth_provider in missing:
            for index in reversed(key_indexes):
                if index == start and index + 1 < end:
                    lines[index + 1] = re.sub(
                        r"^" + re.escape(indent) + r"\s+",
                        indent + "- ", lines[index + 1], count=1,
                    )
                del lines[index]
                changed = True
            continue
        if not _provider_enabled(name, cfg):
            del lines[start:end]
            changed = True
            continue
        key = (
            _get_key(auth_provider)
            if cfg.get("auth", {}).get("type") == "common_auth"
            else _get_key(auth_provider)
        )
        if not key:
            continue
        if key_indexes:
            first = key_indexes[0]
            replacement = indent + (
                "- api_key: " if first == start else "  api_key: "
            ) + json.dumps(key) + "\n"
            if lines[first] != replacement:
                lines[first] = replacement
                changed = True
            for index in reversed(key_indexes[1:]):
                del lines[index]
                changed = True
        else:
            replacement = indent + "  api_key: " + json.dumps(key) + "\n"
            lines.insert(start + 1, replacement)
            changed = True
    if not changed:
        return
    path = pathlib.Path(HERMES_CONFIG)
    fd, tmp_name = tempfile.mkstemp(prefix=".providers.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as handle:
            handle.writelines(lines)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, HERMES_CONFIG)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def _sync_hermes_mirror(servers, refreshed, authoritative_missing=None):
    with _consumer_sync_lock():
        return _sync_hermes_mirror_once(servers, refreshed, authoritative_missing)


def _sync_hermes_mirror_once(servers, refreshed, authoritative_missing=None):
    """Reconcile Hermes config (~/.hermes/config.yaml) custom_providers[]
    against provider enablement.

    Enabled fleet providers with a refreshed model list get an entry upserted.
    Existing entries receive current credentials and base URLs even when the
    model request fails; their last-known-good model list remains untouched.
    Disabled fleet providers get their entry removed. Unknown providers
    (not in the registry) are never touched. The registry stays the
    source of provider routing while live /v1/models fetches stay the
    source of model availability. Network-optional: missing PyYAML or an
    unreadable config skips silently, so a mirror failure can never crash
    the nightly pass.
    """
    try:
        import yaml  # PyYAML is optional: skip silently when absent.
    except ImportError:
        _sync_hermes_credentials_without_yaml(servers, authoritative_missing)
        return
    if not os.path.exists(HERMES_CONFIG):
        return
    try:
        with open(HERMES_CONFIG) as handle:
            config = yaml.safe_load(handle)
    except Exception:
        return
    if not isinstance(config, dict):
        return
    custom = config.get("custom_providers")
    if not isinstance(custom, list):
        return
    changed = False
    authoritative_missing = authoritative_missing or set()
    for name, cfg in servers.items():
        auth_provider = _auth_provider(name, cfg)
        if auth_provider in authoritative_missing:
            # Keep non-secret routing/model metadata so a later successful
            # credential refresh can restore this provider without /models.
            entry = next(
                (item for item in custom
                 if isinstance(item, dict) and item.get("name") == name), None
            )
            if entry is not None and "api_key" in entry:
                del entry["api_key"]
                changed = True
            continue
        if _provider_enabled(name, cfg) and auth_provider not in authoritative_missing:
            key = (
                _get_key(auth_provider)
                if cfg.get("auth", {}).get("type") == "common_auth"
                else _get_key(auth_provider)
            )
            entry = next(
                (
                    item
                    for item in custom
                    if isinstance(item, dict) and item.get("name") == name
                ),
                None,
            )
            if entry is not None:
                if key and entry.get("api_key") != key:
                    entry["api_key"] = key
                    changed = True
                base_url = cfg["baseURL"]
                if entry.get("base_url") != base_url:
                    entry["base_url"] = base_url
                    changed = True
                if name in refreshed:
                    models = _hermes_models(refreshed[name])
                    if models and entry.get("models") != models:
                        entry["models"] = models
                        changed = True
                continue
            if name in refreshed and key:
                models = _hermes_models(refreshed[name])
                if models:
                    custom.append({
                        "name": name,
                        "models": models,
                        "base_url": cfg["baseURL"],
                        "api_key": key,
                    })
                    changed = True
            continue
        # Disabled providers are removed.
        before = len(custom)
        custom[:] = [
            item
            for item in custom
            if not (isinstance(item, dict) and item.get("name") == name)
        ]
        if len(custom) != before:
            changed = True
    if not changed:
        return
    directory = os.path.dirname(HERMES_CONFIG)
    pathlib.Path(directory).mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".providers.", dir=directory)
    try:
        with os.fdopen(fd, "w") as handle:
            yaml.safe_dump(config, handle, sort_keys=False, allow_unicode=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, HERMES_CONFIG)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
    upserted = [
        name
    for name in servers
        if name in refreshed and _provider_enabled(name, servers[name])
    ]
    removed = [
        name
        for name in servers
        if not _provider_enabled(name, servers[name])
        and any(
            isinstance(item, dict) and item.get("name") == name
            for item in config.get("custom_providers", [])
        )
    ]
    for name in upserted:
        print(
            f"  hermes: {name}: {len(_hermes_models(refreshed[name]))} models mirrored",
            file=sys.stderr,
        )
    for name in removed:
        print(f"  hermes: {name}: entry removed (disabled)", file=sys.stderr)


PI_THINKING_LEVELS = frozenset(("minimal", "low", "medium", "high", "xhigh", "max"))


def _pi_model_entry(model_id, config, capability=None):
    """Project one model into Pi's shape using the shared capability record.

    ``config`` remains the inventory/cost fallback for compatibility with
    older callers. Capability fields are only added when the producer made
    them known; an unknown field is omitted instead of being guessed.
    """
    limit = config.get("limit", {}) if isinstance(config, dict) else {}
    cost = config.get("cost", {}) if isinstance(config, dict) else {}
    context = as_int(limit.get("context"), 32768)
    output = as_int(limit.get("output"), 16384)
    projected = {
        "id": model_id,
        "name": model_id,
        "contextWindow": context,
        "maxTokens": output,
        "cost": {
            "input": as_number(cost.get("input")),
            "output": as_number(cost.get("output")),
            "cacheRead": as_number(cost.get("cache_read")),
            "cacheWrite": 0,
        },
    }
    if not isinstance(capability, dict):
        return projected

    # These fields are capability-owned. Start each successful projection
    # without stale values so an explicit unknown/none state is represented by
    # omission (or false for explicit reasoning support) rather than by a
    # previous run's guess.
    for field in ("input", "reasoning", "thinkingLevelMap"):
        projected.pop(field, None)

    # The normalized producer record is authoritative for these scalar
    # metadata fields when it has a value, with the existing inventory shape
    # retained as a safe fallback for an unknown optional value.
    if capability.get("context") is not None:
        projected["contextWindow"] = as_int(capability["context"], context)
    if capability.get("output") is not None:
        projected["maxTokens"] = as_int(capability["output"], output)
    capability_cost = capability.get("cost")
    if isinstance(capability_cost, dict):
        for source, target in (("input", "input"), ("output", "output"), ("cache_read", "cacheRead")):
            if capability_cost.get(source) is not None:
                projected["cost"][target] = as_number(
                    capability_cost[source], projected["cost"][target]
                )

    modalities = capability.get("input_modalities")
    if (
        isinstance(modalities, dict)
        and modalities.get("state") == "known"
        and isinstance(modalities.get("values"), list)
        and all(isinstance(value, str) for value in modalities["values"])
    ):
        projected["input"] = list(modalities["values"])

    reasoning = capability.get("reasoning")
    if isinstance(reasoning, dict):
        support = reasoning.get("support")
        if support in ("full", "partial"):
            projected["reasoning"] = True
        elif support == "none":
            projected["reasoning"] = False
        # Pi's map keys are its own finite levels. Keep a provider's exact
        # native strings as values, but never invent mappings for labels Pi
        # cannot represent (and never add an explicit `off` mapping).
        efforts = reasoning.get("supported_efforts")
        if support == "full" and isinstance(efforts, list):
            level_map = {
                effort: effort
                for effort in efforts
                if isinstance(effort, str) and effort in PI_THINKING_LEVELS
            }
            if level_map:
                projected["thinkingLevelMap"] = level_map
    return projected


def _sync_pi_models_mirror(servers, refreshed):
    """Upsert successful live refreshes into Miniharness/Pi models.json.

    Existing defaults, tiers, and unrelated fleet providers are preserved. A failed
    or empty refresh never replaces the last known model inventory.
    """
    config = load_json_or_quarantine(PI_MODELS_PATH)
    if not isinstance(config, dict):
        config = {}
    providers = config.get("providers")
    if not isinstance(providers, dict):
        providers = {}
    capabilities = _load_capabilities()
    capability_providers = capabilities.get("providers", {})
    if not isinstance(capability_providers, dict):
        capability_providers = {}
    changed = False
    for name, models in refreshed.items():
        server = servers.get(name)
        if not isinstance(server, dict) or not isinstance(models, dict) or not models:
            continue
        # A successful refresh writes capabilities before this mirror runs.
        # Read that normalized snapshot rather than projecting the lossy
        # OpenCode model config. Missing/invalid data leaves the previous Pi
        # projection untouched, preserving the last-known-good inventory.
        snapshot = capability_providers.get(name)
        cached_models = snapshot.get("models") if isinstance(snapshot, dict) else None
        if not isinstance(cached_models, dict) or not cached_models:
            continue
        existing = providers.get(name)
        if not isinstance(existing, dict):
            existing = {}
        projected = dict(existing)
        projected["base_url"] = server["baseURL"]
        projected["provider_type"] = "OpenAICompatible"
        # Pi-side consumers authenticate by stored-credential name, which is
        # not always the provider name: OpenCode Go and Zen are separate
        # enrollments sharing one key. Project the indirection only when it
        # actually differs, and clear a stale one if the registry drops it.
        auth_entry = server.get("auth")
        credential = auth_entry.get("provider") if isinstance(auth_entry, dict) else None
        if isinstance(credential, str) and credential and credential != name:
            projected["auth_key"] = credential
        else:
            projected.pop("auth_key", None)
        # Endpoint-required request headers (OpenCode Go rejects requests with
        # no x-opencode-session). Pi-side consumers substitute {session_id}.
        headers = server.get("headers")
        if isinstance(headers, dict) and headers:
            projected["headers"] = headers
        else:
            projected.pop("headers", None)
        projected["models"] = [
            _pi_model_entry(model_id, models.get(model_id, {}), capability)
            for model_id, capability in cached_models.items()
            if model_id
        ]
        if providers.get(name) != projected:
            providers[name] = projected
            changed = True
    if not changed:
        return
    config["providers"] = providers
    save_json_atomic(PI_MODELS_PATH, config)
    for name in refreshed:
        if name in servers and isinstance(refreshed[name], dict) and refreshed[name]:
            print(
                f"  pi: {name}: {len(capability_providers.get(name, {}).get('models', {}))} models mirrored",
                file=sys.stderr,
            )


def _get_key(provider):
    """Read the credential reconciled for the current Auth account."""
    return cache_get(provider)


# --- registry / servers ------------------------------------------------


def get_auth(auth_cfg):
    if auth_cfg is None:
        return None, None
    atype = auth_cfg.get("type")
    if atype == "auth_json":
        provider = auth_cfg.get("provider", "")
        key = _get_key(provider)
        if key:
            return "api_key", key
    elif atype == "common_auth":
        provider = auth_cfg.get("provider", "")
        key = _get_key(provider)
        if key:
            return "api_key", key
    elif atype == "api_key":
        return "api_key", auth_cfg["key"]
    elif atype == "bearer":
        return "bearer", auth_cfg["key"]
    return None, None


def as_number(value, default=0):
    if value is None:
        return default
    if isinstance(value, (int, float)):
        return value
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def as_int(value, default):
    number = as_number(value, default)
    try:
        return int(number)
    except (TypeError, ValueError):
        return default


MODELS_DEV_URL = os.environ.get("MODELS_DEV_URL", "https://models.dev/api.json")
_MODELS_DEV_CACHE = None


def _models_dev_catalog():
    """Fetch models.dev once per process. Returns None when unavailable."""
    global _MODELS_DEV_CACHE
    if _MODELS_DEV_CACHE is None:
        request = urllib.request.Request(MODELS_DEV_URL)
        request.add_header("Accept", "application/json")
        # models.dev rejects the default urllib agent with 403.
        request.add_header("User-Agent", "providers/1.0")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                _MODELS_DEV_CACHE = json.load(response)
        except Exception as exc:
            print(
                f"  Warning: models.dev unavailable ({exc}); using provider-reported limits only",
                file=sys.stderr,
            )
            _MODELS_DEV_CACHE = {}
    return _MODELS_DEV_CACHE or None


def _enrich_rows_from_models_dev(name, cfg, rows):
    """Fill in limits the provider's own /models endpoint left out.

    Several endpoints (OpenCode Zen and Go, DeepSeek, Meta, Cloudflare) return
    bare model names with no size limits. The projection then falls back to a
    placeholder that no consumer can tell apart from a reported value, so a
    model with a million-token context is published as 32768 and every tool
    reading the registry compacts far too early. models.dev is OpenCode's own
    published catalogue and already uses this module's `limit: {context,
    output}` shape. A value the provider actually reported always wins; this
    only fills gaps.
    """
    key = cfg.get("models_dev")
    if not key:
        return rows
    catalog = _models_dev_catalog()
    entry = catalog.get(key) if isinstance(catalog, dict) else None
    published = entry.get("models") if isinstance(entry, dict) else None
    if not isinstance(published, dict):
        if catalog is not None:
            print(f"  Warning: models.dev has no provider '{key}' for {name}", file=sys.stderr)
        return rows
    enriched = []
    filled = 0
    for row in rows:
        if not isinstance(row, dict):
            enriched.append(row)
            continue
        # Registry-supplied rows are shared state; never mutate them in place.
        row = dict(row)
        model = published.get(row.get("id"))
        limit = model.get("limit") if isinstance(model, dict) else None
        if isinstance(limit, dict):
            context = as_int(limit.get("context"), 0)
            output = as_int(limit.get("output"), 0)
            touched = False
            if row.get("context_length") is None and context > 0:
                row["context_length"] = context
                touched = True
            if _model_output_limit(row) is None and output > 0:
                row["max_completion_tokens"] = output
                touched = True
            if touched:
                filled += 1
        enriched.append(row)
    if filled:
        print(f"  {name}: {filled} models took limits from models.dev", file=sys.stderr)
    return enriched


def _opencode_output_limit(output, context):
    """Give OpenCode a finite ceiling for an unbounded provider limit."""
    if as_number(output, None) == -1:
        return as_int(context, 32768)
    return output


def fetch_models(base_url, auth_cfg):
    url = base_url.rstrip("/") + "/models"
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", "providers/1.0")
    auth_type, auth_val = get_auth(auth_cfg)
    if auth_type in ("api_key", "bearer"):
        req.add_header("Authorization", f"Bearer {auth_val}")
    try:
        global _LAST_FETCH_RAW, _LAST_FETCH_ENDPOINT
        with urllib.request.urlopen(req, timeout=15) as resp:
            _LAST_FETCH_ENDPOINT = url
            _LAST_FETCH_RAW = resp.read()
            return json.loads(_LAST_FETCH_RAW)
    except urllib.error.HTTPError as e:
        print(f"  HTTP {e.code} fetching {url}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"  Error fetching {url}: {e}", file=sys.stderr)
        return None


def _model_matches_allow_policy(model_id, cfg):
    """Return whether one model id passes a registry-owned allow policy."""
    allow_ids = {
        value.casefold()
        for value in cfg.get("model_allow_ids", [])
        if isinstance(value, str) and value
    }
    allow_suffixes = tuple(
        value.casefold()
        for value in cfg.get("model_allow_suffixes", [])
        if isinstance(value, str) and value
    )
    if not allow_ids and not allow_suffixes:
        return True
    lowered = model_id.casefold()
    return lowered in allow_ids or lowered.endswith(allow_suffixes)


def _filter_models(name, cfg, models_list):
    """Apply registry model admission before writing any consumer mirror."""
    allow_ids = cfg.get("model_allow_ids", [])
    allow_suffixes = cfg.get("model_allow_suffixes", [])
    if allow_ids or allow_suffixes:
        before = len(models_list)
        models_list = [
            model for model in models_list
            if isinstance(model, dict)
            and isinstance(model.get("id"), str)
            and _model_matches_allow_policy(model["id"], cfg)
        ]
        excluded = before - len(models_list)
        if excluded:
            print(f"  {name}: {excluded} models excluded by registry allowlist", file=sys.stderr)
    exclude_prefixes = tuple(
        prefix for prefix in cfg.get("model_exclude_prefixes", []) if prefix
    )
    if exclude_prefixes:
        before = len(models_list)
        models_list = [
            model for model in models_list
            if isinstance(model, dict)
            and not str(model.get("id", "")).startswith(exclude_prefixes)
        ]
        excluded = before - len(models_list)
        if excluded:
            print(f"  {name}: {excluded} models excluded by registry prefix", file=sys.stderr)
    return models_list


def _grimoire_price_per_token(value):
    return as_number(value) / 1_000_000


def model_to_config_grimoire(m):
    cost = m.get("cost", {})
    context = as_int(m.get("context"), 32768)
    output = as_int(m.get("output"), 16384)
    return {
        "limit": {
            "context": context,
            "output": _opencode_output_limit(output, context),
        },
        "cost": {
            "input": _grimoire_price_per_token(cost.get("input")),
            "output": _grimoire_price_per_token(cost.get("output")),
            "cache_read": _grimoire_price_per_token(cost.get("cache_read")),
        },
    }


def model_to_config_openai(m):
    context = m.get("context_length", 32768)
    output = _model_output_limit(m, 16384)
    return {
        "limit": {
            "context": context,
            "output": _opencode_output_limit(output, context),
        },
        "cost": {"input": 0, "output": 0, "cache_read": 0},
    }


FORMAT_HANDLERS = {
    "grimoire": model_to_config_grimoire,
    "openai": model_to_config_openai,
}


def _grimoire_url():
    import socket
    host = socket.gethostname()
    if "grimoire" in host.lower():
        return "http://localhost:9001/v1"
    return "https://chat.lost.plus/v1"


def refresh_server(name, cfg):
    base_url = cfg["baseURL"]
    if name == "grimoire":
        base_url = _grimoire_url()
    fmt = cfg.get("api_format", "openai")
    handler = FORMAT_HANDLERS.get(fmt, FORMAT_HANDLERS["openai"])
    npm = cfg.get("npm", "@ai-sdk/openai-compatible")
    print(f"  {name} ({base_url}) ...", file=sys.stderr)
    models_list = cfg.get("models", [])
    fetched_payload = None
    global _LAST_FETCH_RAW, _LAST_FETCH_ENDPOINT
    _LAST_FETCH_RAW = None
    _LAST_FETCH_ENDPOINT = None
    if not models_list:
        resp = fetch_models(base_url, cfg.get("auth"))
        if resp is None:
            return False
        fetched_payload = resp
        try:
            models_list = _response_rows(resp)
        except ValueError as exc:
            print(f"  Warning: malformed models response for {name}: {exc}", file=sys.stderr)
            return False
    if not models_list:
        print(f"  Warning: no models returned for {name}", file=sys.stderr)
        return False
    models_list = _filter_models(name, cfg, models_list)
    if not models_list:
        print(f"  Warning: all models excluded by registry policy for {name}", file=sys.stderr)
        return False
    # After admission, so only models this machine will actually use are looked up.
    models_list = _enrich_rows_from_models_dev(name, cfg, models_list)
    models = {}
    for m in models_list:
        model_id = m.get("id", "")
        if not model_id:
            continue
        models[model_id] = handler(m)
    snapshot = _capability_snapshot(
        name,
        {**cfg, "baseURL": base_url},
        payload=fetched_payload,
        rows=models_list,
        static=fetched_payload is None,
        raw_bytes=_LAST_FETCH_RAW,
    )
    _update_capability_cache(name, snapshot)
    opencode = load_json_or_quarantine(OPENCODE_PATH)
    provider_block = opencode.get("provider", {})
    existing = provider_block.setdefault(name, {})
    existing["npm"] = npm
    existing["name"] = name
    if "options" not in existing:
        existing["options"] = {"baseURL": base_url}
    else:
        existing["options"]["baseURL"] = base_url
    existing["models"] = models
    provider_block[name] = existing
    opencode["provider"] = provider_block
    save_json_atomic(OPENCODE_PATH, opencode)
    jsonc_path = OPENCODE_PATH.replace(".json", ".jsonc")
    if jsonc_path != OPENCODE_PATH and os.path.exists(jsonc_path):
        os.remove(jsonc_path)
        print(f"  Removed stale {os.path.basename(jsonc_path)}", file=sys.stderr)
    print(f"  {name}: {len(models)} models updated", file=sys.stderr)
    return models


PROVIDER_URLS = {
    "grimoire": "http://localhost:9001 (self-hosted)",
    "commandcode": "https://commandcode.ai/studio → Settings → API Keys",
    "deepseek": "https://platform.deepseek.com/api_keys",
    # META_API_KEY is the same Model API key muse reads for headless runs.
    "meta": "https://dev.meta.ai",
}


def _load_servers():
    """Load OpenAI-compatible fleet providers from the canonical provider registry."""
    try:
        registry = _validate_registry(load_json(REGISTRY_PATH))
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"Cannot read provider registry {REGISTRY_PATH}: {exc}", file=sys.stderr)
        return None
    servers = _servers_from_registry(registry)
    return servers


def _load_retired():
    """Names the registry has withdrawn, for the prune. Empty on any error:
    a registry we cannot read is never grounds for deleting a credential."""
    try:
        registry = _validate_registry(load_json(REGISTRY_PATH))
    except (OSError, json.JSONDecodeError, ValueError):
        return []
    return list(registry.get("retired_providers", []))


def _prune_retired(retired):
    """Delete every trace of a withdrawn provider from this machine.

    Each consumer write path is an upsert scoped to a name, so dropping a
    provider from the registry leaves its credential and its model list behind
    on every machine indefinitely -- and the credential cache explicitly never
    deletes an entry only it knows about, which then re-mirrors the dead key
    into .zshenv and auth.json on the next pass. This is the one sweep that
    closes that loop. Idempotent and silent when there is nothing to remove,
    because it runs on every nightly refresh.
    """
    retired = [name for name in retired if name]
    if not retired:
        return
    removed = set()

    cache = _load_cache()
    if any(name in cache for name in retired):
        for name in retired:
            if cache.pop(name, None) is not None:
                removed.add(name)
        _save_cache(cache)

    # The whole auth.json entry goes, api-type or OAuth: an OAuth entry left here
    # is re-exported as {NAME}_OAUTH_TOKEN on every pass. _write_auth_mirror's
    # managed_absent would only drop the api-type one, and stays that way for its
    # own callers, where opencode owns the OAuth entry and must keep it.
    if os.path.exists(OLD_AUTH_PATH):
        try:
            auth = load_json(OLD_AUTH_PATH)
        except (OSError, json.JSONDecodeError):
            auth = None
        if isinstance(auth, dict) and any(name in auth for name in retired):
            for name in retired:
                if auth.pop(name, None) is not None:
                    removed.add(name)
            save_json_atomic(OLD_AUTH_PATH, auth, mode=0o600)
    # Rewritten from the pruned cache either way: an earlier release may have
    # left the export in .zshenv after the cache entry was already gone. Refresh
    # calls _sync_mirrors() right after this, so these two look redundant there --
    # they are what makes the sweep complete on its own, for every other caller.
    _write_auth_mirror(cache)
    _write_env_mirror(cache)

    state = _load_provider_state()
    if isinstance(state, dict):
        providers = state.get("providers")
        if isinstance(providers, dict):
            hit = {name for name in retired if providers.pop(name, None) is not None}
            if hit:
                removed |= hit
                save_json_atomic(STATE_PATH, state)

    capabilities = _load_capabilities()
    known = capabilities.get("providers")
    if isinstance(known, dict):
        hit = {name for name in retired if known.pop(name, None) is not None}
        if hit:
            removed |= hit
            _save_capabilities(capabilities)

    opencode = load_json_or_quarantine(OPENCODE_PATH)
    changed = False
    block = opencode.get("provider")
    if isinstance(block, dict):
        for name in retired:
            if block.pop(name, None) is not None:
                removed.add(name)
                changed = True
    disabled = opencode.get("disabled_providers")
    if isinstance(disabled, list) and any(name in disabled for name in retired):
        opencode["disabled_providers"] = [n for n in disabled if n not in retired]
        if not opencode["disabled_providers"]:
            del opencode["disabled_providers"]
        changed = True
    if changed:
        save_json_atomic(OPENCODE_PATH, opencode)

    # Pi keeps its own catalogue, and it is an upsert too. Only the provider
    # entries are ours: Pi's model ids are bare and often vendor-prefixed
    # (deepseek/..., meta/... under openrouter), so nothing else in this file can
    # be matched against a provider name without reading a vendor as a provider.
    pi = load_json_or_quarantine(PI_MODELS_PATH)
    if isinstance(pi, dict) and isinstance(pi.get("providers"), dict):
        hit = {name for name in retired if pi["providers"].pop(name, None) is not None}
        if hit:
            removed |= hit
            save_json_atomic(PI_MODELS_PATH, pi)

    removed.update(_prune_retired_hermes(retired))

    for name in sorted(removed):
        print(f"  {name}: retired; removed from this machine", file=sys.stderr)


def _prune_retired_hermes(retired):
    """Drop retired entries from Hermes custom_providers[]. Needs PyYAML;
    without it the entry is left alone rather than edited by hand, the same
    way the credential sync degrades. Returns the names actually removed, so
    the caller reports only what it really did."""
    try:
        import yaml
    except ImportError:
        return set()
    if not os.path.exists(HERMES_CONFIG):
        return set()
    try:
        with open(HERMES_CONFIG) as handle:
            config = yaml.safe_load(handle)
    except Exception:
        return set()
    if not isinstance(config, dict):
        return set()
    custom = config.get("custom_providers")
    if not isinstance(custom, list):
        return set()
    hit = {
        item["name"] for item in custom
        if isinstance(item, dict) and item.get("name") in retired
    }
    if not hit:
        return set()
    custom[:] = [
        item for item in custom
        if not (isinstance(item, dict) and item.get("name") in retired)
    ]
    directory = os.path.dirname(HERMES_CONFIG)
    pathlib.Path(directory).mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".providers.", dir=directory)
    try:
        with os.fdopen(fd, "w") as handle:
            yaml.safe_dump(config, handle, sort_keys=False, allow_unicode=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, HERMES_CONFIG)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
    return hit


def _servers_from_registry(registry):
    """Extract OpenAI-compatible credentialed servers from a validated registry.

    Split out so the fixture registry can be consulted without touching
    the real one (REGISTRY_PATH is env-overridable, so _load_servers can
    only ever see one registry per process).
    """
    providers = registry.get("providers")
    servers = {}
    for name, provider in providers.items():
        if not isinstance(provider, dict):
            continue
        auth = provider.get("auth", {})
        if provider.get("provider_type") != "OpenAICompatible":
            continue
        if not isinstance(auth, dict) or auth.get("type") not in ("api-key", "common-auth"):
            continue
        base_url = provider.get("base_url")
        auth_key = auth.get("key")
        if not all(isinstance(value, str) and value for value in (name, base_url, auth_key)):
            continue
        resolved_auth = {"type": "auth_json", "provider": auth_key}
        if auth.get("type") == "common-auth":
            scope = auth.get("scope")
            if not isinstance(scope, str) or not scope:
                continue
            resolved_auth = {"type": "common_auth", "provider": auth_key, "scope": scope}
        servers[name] = {
            "baseURL": base_url,
            "api_format": provider.get("api_format", "openai"),
            "npm": provider.get("npm", "@ai-sdk/openai-compatible"),
            "auth": resolved_auth,
            "registry_enabled": provider.get("enabled") is True,
            "models": provider.get("models", []),
            "model_exclude_prefixes": provider.get("model_exclude_prefixes", []),
            "model_allow_suffixes": provider.get("model_allow_suffixes", []),
            "model_allow_ids": provider.get("model_allow_ids", []),
            "headers": provider.get("headers", {}),
            "models_dev": provider.get("models_dev", ""),
        }
    return servers


def _load_provider_state():
    if not os.path.exists(STATE_PATH):
        return {"version": PROVIDER_STATE_VERSION, "providers": {}}
    try:
        data = load_json(STATE_PATH)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Cannot read provider state {STATE_PATH}; all providers are disabled: {exc}", file=sys.stderr)
        return None
    if not _valid_provider_state(data):
        print(f"Invalid provider state {STATE_PATH}; all providers are disabled", file=sys.stderr)
        return None
    return data


def _valid_provider_state(data):
    if (
        not isinstance(data, dict)
        or data.get("version") != PROVIDER_STATE_VERSION
        or not isinstance(data.get("providers"), dict)
    ):
        return False
    return all(
        isinstance(name, str)
        and NAME_RE.fullmatch(name)
        and isinstance(entry, dict)
        and set(entry) == {"enabled"}
        and isinstance(entry["enabled"], bool)
        for name, entry in data["providers"].items()
    )


def _auth_provider(name, cfg):
    auth = cfg.get("auth", {})
    return auth.get("provider", name) if isinstance(auth, dict) else name


def _provider_enabled(name, cfg):
    provider_state = _load_provider_state()
    if provider_state is None:
        return False
    state = provider_state.get("providers", {}).get(name, {})
    if isinstance(state, dict) and "enabled" in state:
        return state["enabled"] is True
    return cfg.get("registry_enabled") is True and bool(_get_key(_auth_provider(name, cfg)))


def _sync_opencode_provider_statuses(servers):
    """Mirror managed provider status without changing unrelated providers."""
    opencode = load_json_or_quarantine(OPENCODE_PATH)
    configured_disabled = opencode.get("disabled_providers", [])
    if not isinstance(configured_disabled, list):
        configured_disabled = []
    managed = set(servers)
    disabled = [name for name in configured_disabled if name not in managed]
    disabled.extend(
        name for name, cfg in servers.items() if not _provider_enabled(name, cfg)
    )
    if disabled:
        opencode["disabled_providers"] = disabled
    else:
        opencode.pop("disabled_providers", None)
    save_json_atomic(OPENCODE_PATH, opencode)


def _sync_opencodex_provider_statuses(restart=True):
    """Mirror provider status into OpenCodex and the Codex model catalog.

    `restart=False` is for the refresh path. The nightly refresh runs unattended,
    and a proxy restart aborts whatever turn is in flight; the
    config is brought current on disk and the daily harnesses pass is what
    restarts the proxy onto it.
    """
    if not (os.path.isfile(OPENCODEX_BIN) and os.access(OPENCODEX_BIN, os.X_OK)):
        return
    argv = [OPENCODEX_BIN, "__apply"] + ([] if restart else ["--no-restart"])
    if subprocess.run(argv).returncode:
        print("  OpenCodex config unchanged; run: setup update opencodex", file=sys.stderr)
        return
    ocx = shutil.which("ocx")
    if ocx is None:
        return
    if subprocess.run([ocx, "sync"]).returncode:
        print("  Codex model catalog unchanged; run: ocx sync", file=sys.stderr)


def _valid_base_url(value):
    parsed = urllib.parse.urlsplit(value)
    return (
        parsed.scheme in {"http", "https"}
        and bool(parsed.hostname)
        and parsed.username is None
        and parsed.password is None
        and not parsed.query
        and not parsed.fragment
        and not any(character.isspace() for character in value)
    )


def _validate_registry(data):
    if not isinstance(data, dict) or data.get("version") != 1:
        raise ValueError("registry version must be 1")
    known = {"version", "providers", "retired_providers", "retired_providers_comment"}
    if not set(data) <= known or not {"version", "providers"} <= set(data):
        raise ValueError("registry must contain only version, providers, and retired_providers")
    providers = data.get("providers")
    if not isinstance(providers, dict):
        raise ValueError("registry providers must be an object")
    retired = data.get("retired_providers", [])
    if not isinstance(retired, list):
        raise ValueError("retired_providers must be a list")
    # Credential names a live provider resolves through, which is not always its
    # own name: opencode-zen shared one enrollment with opencode-go, filed under
    # opencode-go. Retiring the name a live provider borrows would delete the
    # credential it needs, and the sweep's read-back filters then block the vault
    # from ever healing it -- a silent, permanent key: x on a provider still in use.
    borrowed = {
        auth["key"] for provider in providers.values()
        if isinstance(provider, dict)
        for auth in [provider.get("auth")]
        if isinstance(auth, dict) and isinstance(auth.get("key"), str)
    }
    for name in retired:
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            raise ValueError(f"invalid retired provider: {name}")
        # A name cannot be both live and retired: the prune would delete the
        # credential the refresh is about to write back, every hour.
        if name in providers:
            raise ValueError(f"{name} is both a provider and retired")
        if name in borrowed:
            raise ValueError(f"{name} is the credential of a live provider and cannot be retired")
    if len(retired) != len(set(retired)):
        raise ValueError("duplicate retired provider")
    for provider_name, provider in providers.items():
        if not NAME_RE.fullmatch(provider_name) or not isinstance(provider, dict):
            raise ValueError(f"invalid provider: {provider_name}")
        if provider.get("provider_type") not in {"DirectAnthropic", "OpenAICompatible", "OpenAIResponses"}:
            raise ValueError(f"invalid provider_type for {provider_name}")
        if not isinstance(provider.get("base_url"), str) or not _valid_base_url(provider["base_url"]):
            raise ValueError(f"invalid base_url for {provider_name}")
        auth = provider.get("auth")
        if not isinstance(auth, dict):
            raise ValueError(f"invalid auth descriptor for {provider_name}")
        if provider["provider_type"] == "OpenAICompatible":
            auth_type = auth.get("type")
            if auth_type == "api-key" and auth.get("store") != "opencode":
                raise ValueError(f"invalid API-key auth descriptor for {provider_name}")
            if auth_type == "common-auth" and not NAME_RE.fullmatch(auth.get("scope", "")):
                raise ValueError(f"invalid Common Auth descriptor for {provider_name}")
            if auth_type not in ("api-key", "common-auth"):
                raise ValueError(f"invalid auth descriptor for {provider_name}")
            if not NAME_RE.fullmatch(auth.get("key", "")):
                raise ValueError(f"invalid API-key auth descriptor for {provider_name}")
            if not isinstance(provider.get("enabled"), bool):
                raise ValueError(f"enabled for {provider_name} must be a boolean")
            if provider.get("api_format") not in FORMAT_HANDLERS:
                raise ValueError(f"invalid api_format for {provider_name}")
            if not isinstance(provider.get("npm"), str) or not provider["npm"]:
                raise ValueError(f"invalid npm package for {provider_name}")
            models = provider.get("models", [])
            if not isinstance(models, list):
                raise ValueError(f"models for {provider_name} must be a list")
            model_ids = []
            for model in models:
                if (
                    not isinstance(model, dict)
                    or not isinstance(model.get("id"), str)
                    or not model["id"]
                ):
                    raise ValueError(f"invalid static model for {provider_name}")
                model_ids.append(model["id"])
            if len(model_ids) != len(set(model_ids)):
                raise ValueError(f"duplicate static model for {provider_name}")
            for field in ("model_allow_ids", "model_allow_suffixes"):
                values = provider.get(field, [])
                if not isinstance(values, list):
                    raise ValueError(f"{field} for {provider_name} must be a list")
                if any(
                    not isinstance(value, str) or not value or any(ord(c) < 32 for c in value)
                    for value in values
                ):
                    raise ValueError(f"invalid {field} entry for {provider_name}")
                if len(values) != len(set(values)):
                    raise ValueError(f"duplicate {field} entry for {provider_name}")
            exclude_prefixes = provider.get("model_exclude_prefixes", [])
            if not isinstance(exclude_prefixes, list):
                raise ValueError(f"model_exclude_prefixes for {provider_name} must be a list")
            for prefix in exclude_prefixes:
                if not isinstance(prefix, str) or not prefix:
                    raise ValueError(f"invalid model_exclude_prefixes entry for {provider_name}")
        elif auth.get("type") != "oauth" or not isinstance(auth.get("provider"), str):
            raise ValueError(f"invalid OAuth descriptor for {provider_name}")
    return data


def _conforming_item_name(name):
    """C1 convention: {PROVIDER}_API_KEY, where PROVIDER is a lowercase
    alphanumeric/hyphen provider name uppercased with '-' -> '_' (so the item
    is uppercase letters/digits/underscores, ending in _API_KEY)."""
    if not name.endswith("_API_KEY"):
        return False
    stem = name[: -len("_API_KEY")]
    return bool(re.fullmatch(r"[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*", stem))


def refresh_models():
    """Refresh enabled model inventories after fleet has synced credentials."""
    servers = _load_servers()
    if servers is None:
        raise ValueError("cannot read provider registry")
    with _consumer_sync_lock():
        refreshed = {}
        for name, cfg in servers.items():
            if _provider_enabled(name, cfg):
                models = refresh_server(name, cfg)
                if isinstance(models, dict):
                    refreshed[name] = models
        _sync_hermes_mirror(servers, refreshed)
        _sync_pi_models_mirror(servers, refreshed)
        _sync_opencodex_provider_statuses(restart=False)


def _provider_settings(path=None):
    path = path or SETTINGS_PATH
    value = load_json(path) if os.path.exists(path) else {"version": 2, "enabled": {}}
    if (not isinstance(value, dict) or set(value) != {"version", "enabled"} or value["version"] != 2
            or not isinstance(value["enabled"], dict) or len(value["enabled"]) > 128
            or any(not NAME_RE.fullmatch(n) or n in ("codex", "anthropic") or not isinstance(v, bool)
                   for n, v in value["enabled"].items())):
        raise ValueError("provider settings must contain only account enabled choices")
    return value


def materialize_catalog(context, shared):
    """Join shared definitions with account choices and machine-local native OAuth entries."""
    registry = _validate_registry(shared["registry"])
    if any(n in ("codex", "anthropic") or p["provider_type"] != "OpenAICompatible"
           for n, p in registry["providers"].items()):
        raise ValueError("shared provider catalog contains a native OAuth provider")
    settings = _provider_settings()
    native = _validate_registry(load_json(DEFAULTS_PATH))
    providers = {n: p for n, p in native["providers"].items() if p["provider_type"] != "OpenAICompatible"}
    for name, cfg in registry["providers"].items():
        cfg = dict(cfg)
        cfg["enabled"] = settings["enabled"].get(name, cfg["enabled"])
        providers[name] = cfg
    result = {"version": 1, "providers": providers, "retired_providers": registry.get("retired_providers", [])}
    _validate_registry(result)
    save_json_atomic(REGISTRY_PATH, result)


def bind_account(context):
    """Bind every cached provider key and model list to the active Auth account."""
    with _consumer_sync_lock():
        cache = _load_cache()
        previous = cache.get("_fleet_account")
        if context is not None and previous == context:
            return
        removed = {name for name in cache if not name.startswith("_")}
        _save_cache({"_fleet_account": context})
        _sync_mirrors(managed_absent=removed)
        _prune_retired(sorted(removed))
        _save_capabilities({"version": CAPABILITIES_VERSION, "providers": {}})


def sync_credentials(context, fetch_catalog):
    bind_account(context)
    try:
        shared = fetch_catalog()
        if common_auth_context() != context:
            raise CommonAuthContextChanged("account changed during catalog sync")
        # Validate before replacing the last good cache.
        materialize_catalog(context, shared)
        save_json_atomic(CATALOG_PATH, {"account": context, "catalog": shared})
    except CommonAuthContextChanged:
        bind_account(None)
        raise
    except Exception as exc:
        if getattr(exc, "status", None) == 401:
            bind_account(None)
            raise
        cached = load_json(CATALOG_PATH) if os.path.exists(CATALOG_PATH) else {}
        if cached.get("account") != context:
            raise
        if common_auth_context() != context:
            bind_account(None)
            raise CommonAuthContextChanged("account changed during catalog sync")
        materialize_catalog(context, cached["catalog"])
    registry = _validate_registry(load_json(REGISTRY_PATH))
    servers = _servers_from_registry(registry)
    with _consumer_sync_lock():
        _sync_common_auth(servers)
        if common_auth_context() != context:
            raise ValueError("account changed during provider sync")
        _sync_cache_from_vault(servers)
        if common_auth_context() != context:
            bind_account(None)
            raise ValueError("account changed during provider sync")
        _prune_retired(_load_retired())
        save_json_atomic(STATE_PATH, {"version": 1, "providers": {
            n: {"enabled": p["enabled"] and bool(_get_key(p["auth"]["key"]))}
            for n, p in registry["providers"].items() if p.get("provider_type") == "OpenAICompatible"}})
        _sync_mirrors()
        _sync_opencode_provider_statuses(servers)
        _sync_hermes_mirror(servers, {})
    _sync_pi_models_mirror(servers, {})
    _sync_opencodex_provider_statuses(restart=False)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "__validate":
        raise SystemExit("Private provider engine; managed by fleet")
    try:
        _validate_registry(load_json(sys.argv[2]))
    except (OSError, ValueError) as exc:
        raise SystemExit(str(exc))
