# Architecture and Upgrades

## Layers

| Layer | Source | Runtime |
| --- | --- | --- |
| Control plane | `src/grimoire/` | Python; `DEV_SRC_BIND` currently shadows the image |
| Webui | `webui/` submodule | Host `webui/build` bind shadows the image UI |
| Engine | Dockerfile-pinned `TheTom/llama-cpp-turboquant` | `/opt/grimoire-llama-cpp` in `grimoire:local` |
| Models/state | `/home/yeowool/models`, `state/` | External binds |

`src/grimoire/pflash/deps/llama.cpp` is a converter/PFlash dependency, not the
served engine.

## Fork Deltas

The engine fork adds TurboQuant weights, `turbo2`/`turbo3`/`turbo4` KV,
asymmetric K/V policies, kernels, and model-family fixes over upstream llama.cpp.

Local patches are separate: `AGENTS.md` says
`GRIMOIRE_LLAMA_CPP_APPLY_PATCHES=0`; the Dockerfile defaults to `1` with
`0005` and `0006`. Pass the intended value explicitly before rebuilding.

The webui is a forked llama.cpp SvelteKit UI. The gateway implements the
llama.cpp router endpoints it expects. The fork adds API-key-scoped history,
login/model management, MCP OAuth, agentic tools, artifacts/compaction/context
UI, and system-prompt presets. Never replace it wholesale from upstream.

## Change Matrix

| Change | Required action |
| --- | --- |
| `src/grimoire` | Restart to re-import; no rebuild with `DEV_SRC_BIND` |
| `webui` | `npm ci && npm run build`; no engine rebuild |
| Registry/preset | API update; reload affected active models |
| Compose env/mount | Recreate through the installed service |
| Engine pin/flags/patches/image deps | Rebuild image, then recreate |
| Model files | Validate and load; no rebuild |

## Webui Update

1. Inspect superproject and submodule status, including untracked files.
2. Confirm the submodule origin; update or port within its current branch.
3. Run `npm ci`, `npm run check`, `npm run lint`, then `npm run build`.
4. Test root UI, login, model lifecycle, history, and changed fork features.
5. Record the submodule pointer only when landing the update.

## Engine Update

1. Compare the candidate fork revision with upstream; use
   `records/upstream-intake/README.md` to select intake records.
2. Change the Dockerfile ref and exact SHA; bump `CACHE_BUST` only for stale or
   force-pushed cache.
3. Pass the intended patch setting explicitly.
4. Build the `grimoire` service; recreate through the installed systemd path.
5. Verify:

   ```bash
   /usr/bin/docker exec grimoire \
     /opt/grimoire-llama-cpp/bin/llama-server --version
   ```

6. Smoke affected models, modalities, LoRA/control tokens, KV modes, lifecycle,
   and preset restore.

Read `systemctl cat grimoire.service` before deployment; installed unit state
outranks repo-local unit files.

Native DFlash canaries use
`/tmp/spec-analysis/bee-shallow/build/bin/llama-server`; with
`--cache-type-k turbo4`, set `GGML_DFLASH_GPU_RING=0`.
