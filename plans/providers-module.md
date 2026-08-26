# Plan: `refresh-models` → `providers` (vault-owned credentials)

**Status:** design approved; vault rename phase complete.

## Goal
Make a new `providers` module own the canonical provider API-key store (vaultwarden `llm/` folder), with a CLI+TUI for enrollment, and convert every consumer (opencodex, claudex, opencode, hermes, `.zshenv`) to read from it. This is the first step of the broader move away from opencode: opencode's `auth.json` stops being the source of truth and becomes one more mirror written by `providers`.

**OAuth is out of scope.** OAuth entries (`openai`, `github-copilot`, anthropic) stay owned by their harnesses. `providers` only manages `api`-type keys. OAuth vault items (`OPENAI_REFRESH_TOKEN`, `GITHUB_COPILOT_OAUTH_TOKEN`) are left in place, named, but not enrolled/managed.

## Decisions locked
| # | Decision |
|---|---|
| D1 | Vault = source of truth; local 0600 cache for offline/headless |
| D2 | OAuth excluded; harnesses own OAuth enrollments |
| D3 | opencode keeps reading its native `auth.json` — `providers` becomes the writer (mirror) |
| D4 | `.zshenv` block stays (same markers, same `{PROVIDER}_API_KEY` names) |
| D5 | Hourly timer stays, renamed with module |
| D6 | Vault audit + rename is Phase 1 of this plan (complete) |
| D7 | `crofai_api_key_guest` and `ANTHROPIC_API_KEY` deleted (revoked or unused) |
| D8 | Network optional: `providers sync`/timer fall back to the local cache silently when vault is unreachable (stderr note only); timers never fail on network loss. Keys rotate rarely, so staleness is acceptable. |
| D9 | Vault transport = direct vaultwarden API using `VAULTWARDEN_MCP_TOKEN` / `VAULTWARDEN_SECRETS_TOKEN` (in env). No `bw` CLI, no MCP-server subprocess — the `providers` binary calls the vault HTTP API itself. |

## Target shape
```
~/.config/providers/state.json        # enablement (exists; unchanged shape)
~/.config/providers/credentials.json  # NEW local 0600 cache of vault keys (never hand-written)
~/.zshenv                             # # BEGIN setup:api-keys block — export {PROVIDER}_API_KEY=… (unchanged markers)
~/.local/share/opencode/auth.json     # opencode's native file — providers now writes it (mirror)
vaultwarden: llm/{PROVIDER}_API_KEY   # source of truth
```

## Contracts

### C1 — Secret naming (enforced, now holds in vault)
`{PROVIDER}_API_KEY`, where `{PROVIDER}` = resolved provider name (`-`→`_`, uppercase).
- Provider name comes from the registry's `auth.key` pointer (e.g. `auth.key: "opencode-go"` → `OPENCODE_GO_API_KEY`), not the registry key.
- OAuth items keep `*_OAUTH_TOKEN` / `*_REFRESH_TOKEN` naming (out of scope).
- `providers` refuses to load an item that doesn't match C1. Renames require explicit `--apply`.

### C2 — Store JSON shape (the boundary)
```json
{ "version": 1,
  "providers": {
    "deepseek": { "auth": { "type": "api-key", "store": "vault", "item": "DEEPSEEK_API_KEY" } }
  }
}
```
The retired Claudex registry (`claudex-profiles.json`) keeps its legacy profile shape. Maintained providers and OpenCodex consume the canonical provider registry, whose descriptors retain `auth: {type: api-key, store: opencode, key: …}`; the vault mapping is a `providers` read-time concern, not a registry change.

## Consumers (read paths)

| Consumer | Today reads | New read |
|---|---|---|
| opencodex launcher | `auth.json` for credentials and the generated catalog for model choices | Credentials remain in the providers-written `auth.json`; enrolled OpenAI-compatible model capabilities come from the cache-only `providers capabilities show --json` interface |
| opencode (harness) | native `auth.json` | Unchanged — providers writes the same shape |
| hermes / grimoire skill | `GRIMOIRE_API_KEY` via vaultwarden `get_secret` | Same item name, now enforced by C1 |
| `.zshenv` block | written by refresh-models | written by providers, same names |
| claudex | `auth.json` via `CLAUDEX_AUTH_JSON` | unchanged |

## The `providers` CLI+TUI
```
providers auth <provider> <key>     # enroll → vault (via MCP), refresh cache, mirror opencode + .zshenv, enable
providers auth                      # interactive: list missing keys, prompt per provider (like cmd_auth today)
providers ls                        # providers + enrolled status (key presence only, never the key)
providers enable|disable <p>        # today's set_provider_enabled path
providers sync                      # vault → cache → opencode auth.json → .zshenv (also on timer)
providers audit                     # list llm folder, flag non-conforming items (dry-run rename list)
providers rename --dry-run|--apply  # enforce C1 on existing items (only with explicit apply)
```
TUI: reuse opencodex's fzf-based picker (`opencodex:599-621`).

## Phases

### Phase 1 — Vault normalization ✅ COMPLETE
- Renamed: `commandcode api key`→`COMMANDCODE_API_KEY`, `ollama_api_key`→`OLLAMA_CLOUD_API_KEY`, `Kimi Code API Key`→`KIMICODE_API_KEY`, `GITHUB_COPILOT_TOKEN`→`GITHUB_COPILOT_OAUTH_TOKEN`.
- Deleted (soft): `crofai_api_key_guest` (revoked) and `ANTHROPIC_API_KEY` (unused), both with `deleted:true`; purge with `empty_trash` if desired.
- Verified: 13/13 remaining live items conform to C1.
- Kept but unused: `VAST.ai` (no live provider; flagged in audit, not touched).

### Phase 2 — Store contract + `providers` binary/module
1. Add `files/providers` (Python CLI, derived from `refresh-models` — reuse `load_json_or_quarantine`, `save_json_atomic` (0600 default), `_read_env_block`, `_sync_zsenv_to_auth`, `_load_servers`, `cmd_auth`, `set_provider_enabled`).
2. Vault read/write layer: direct vaultwarden HTTP API using `VAULTWARDEN_MCP_TOKEN` / `VAULTWARDEN_SECRETS_TOKEN` (already in env; the MCP server's wire). Folder `llm`, operations mirror the `vaultwarden_secrets` tool shape (`get_secret`/`add_secret`/`rename_secret`/`delete_secret`). Deterministic load = C1 names. **Network-optional (D8):** on vault unreachable, use the local cache and print a stderr note — never fail the timer.
3. Local cache `credentials.json` (0600, atomic): vault → cache on `sync`/`auth`; read cache first for offline (timer/launchd), vault for freshness on `sync`. On vault unreachable (D8), serve from cache silently + stderr note.
4. Mirror writers: opencode `auth.json` (native shape, api-type entries only) + `.zshenv` block (same names/markers).
5. `files/providers.sh` module (setup-module: providers, script). Rename from `refresh-models.sh`: `install/update/status/uninstall`, `__validate`/`__migrate-state`/`__apply` surface, `record_script_state` "provider-registry" tag.
6. Timer: keep systemd/launchd hourly unit, rename to `providers.{service,timer}` + `com.lost.plus.providers` plist. Same cadence, same `needs-provider-setup` marker path (`~/.local/state/setup/providers.needs-provider-setup`).

### Phase 3 — Migration (order matters) ✅ COMPLETE
1. Read current `~/.local/share/opencode/auth.json` api-type entries → enroll each into vault (matches existing conforming items; skips already-present).
2. Build local cache from vault.
3. Write opencode mirror + `.zshenv` from cache.
4. `setup update providers` converges; state/enablement carried over from `~/.config/providers/state.json` (already the shared path).
5. One-time: delete the now-redundant copy in `auth.json`? **No** — opencode still reads it; it becomes a mirror. Only `providers` writes it going forward.

### Phase 4 — Consumers + retirement ✅ COMPLETE
- `opencodex`: read the providers capability cache through `providers capabilities show --json`; the cache owns enrolled OpenAI-compatible inventory and native reasoning labels. Codex/OAuth routes continue using the generated catalog and proxy inventory as fallback.
- `claudex`: read `auth.json` as before. Verify `opencodex_config_status` blanking still hides keys (it does — `opencodex:572-574`).
- `PROVIDER_CONSUMER_MODULES` in opencodex (`opencodex:61`, test `opencodex-launcher.sh:491`) → `("claudex", "opencodex", "providers")`.
- Manifest (`manifest.tsv:11`), README (`README.md:88`), checksums: `refresh-models` → `providers`, retired row for old module (pattern: claudex's `retired` row).
- Retire `refresh-models` binary/state cleanly (keep vault + auth.json untouched).

### Phase 5 — Tests ✅ COMPLETE
- Rename `refresh-models-{lifecycle,onboarding,providers}.sh` → `providers-*.sh`.
- Update `process-boundaries.sh:25-27` marker path.
- Update `opencodex-launcher.sh:491`, `claudex-lifecycle.sh:15,135`, `opencodex-lifecycle.sh:116,126,129`, `catalog-audience.sh:65` refs.
- New tests: vault-cache read path (mock vault), naming-convention rejection, mirror-writer equivalence (opencode auth.json shape), timer rename.

## Sequencing / fan-out
**No fan-out.** Single coherent slice (the skill's "one slice" case): one shared boundary (the store), order-dependent migration, and consumers that mostly read the same file. After C1+C2 are fixed and Phase 2 lands, consumer adapters could parallelize — but they're trivial (mostly no-ops) and touching the same repo, so keep them sequential.

## Open items
1. `VAST.ai`: no live provider — leave in vault, exclude from presets unless you want it.
2. The extra live `auth.json` providers `alibaba`, `ollama-cloud`, and `opencode-go` remain to be considered as `providers` presets. OpenRouter is enrolled in the canonical provider registry, enabled by default, with live model discovery. The extra providers are not added to the retired `claudex-profiles.json` asset unless you say so.
3. `empty_trash` on `crofai_api_key_guest` and `ANTHROPIC_API_KEY` — your call (soft-deleted items expire in 30 days anyway).

## Capability cache contract

`providers` owns the host-generated `~/.config/providers/capabilities.json`
snapshot (override with `PROVIDERS_CAPABILITIES_PATH` in tests). The file is
versioned, written atomically with mode `0600`, and only replaced by a
successful non-empty model refresh. A malformed snapshot is quarantined as
`capabilities.json.corrupt`; a failed or empty refresh leaves the previous
last-known-good provider snapshot intact.

Each normalized model record includes its provider and model id, exact
advertised input modalities and supported parameters, reasoning support and
native effort labels, context/output/cost metadata, a credential-free `/models`
endpoint, fetch time, raw response SHA-256, metadata fingerprint, and evidence
source. Missing capability metadata is represented as `unknown`; malformed
capability fields are retained as unknown with an error while the model remains
in the inventory. The source is provider `/models` metadata only; it does not
claim a live semantic canary.

Machine consumers use `providers capabilities show [--provider NAME]
[--model ID] --json` for cache-only reads, or `providers capabilities refresh
[--provider NAME] [--model ID] --json` for one provider refresh followed by a
normalized view. JSON is emitted on stdout; diagnostics are emitted on stderr.

OpenCodex treats a successful enrolled-provider snapshot as authoritative for
that provider's model inventory. Its picker preserves exact native effort
labels and uses `default` for omission; a saved legacy `none` value is ignored.
The launcher sends an explicit effort only for a named level, so unknown or
unsupported cache states do not inherit catalog-generated choices.

The Pi/miniharness mirror consumes the same snapshot after provider refresh.
Known input modalities are projected to Pi's `input` field. Reasoning support
maps to `true` for full or partial, `false` for none, and omission for
unknown. `thinkingLevelMap` contains only Pi's representable native level
labels (`minimal`, `low`, `medium`, `high`, `xhigh`, `max`), with provider
strings preserved as values. Missing or invalid refreshed capability data
leaves the last-known-good Pi projection intact.
