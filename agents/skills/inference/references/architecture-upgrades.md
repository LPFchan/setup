# Architecture and Upgrades

## Layers

| Layer | Source | Runtime |
| --- | --- | --- |
| Control plane | `src/grimoire/` | Python; `DEV_SRC_BIND` currently shadows the image |
| Webui | `webui/` submodule | Host `webui/build` bind shadows the image UI |
| Engine | Dockerfile-pinned `TheTom/llama-cpp-turboquant` | `/opt/grimoire-llama-cpp` in `grimoire:local` |
| Mangchi lifecycle | `src/grimoire/mangchi_agent.py`, `etc/mangchi-agent.json` | Residency agent on `mangchi.lost.plus:9700` |
| Remote inference | `vllm-remote` entries in `etc/models.grimoire.json` | Per-model vLLM containers on Mangchi |
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
| Mangchi vLLM pin/patch/image deps | Build from the inference repo root, then restart the residency agent and reload affected models |
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

## Mangchi vLLM Image Update

The Mangchi image applies repo-owned patches from `patches/mangchi-vllm/` to
the exact vLLM SHA pinned in `docker/mangchi-vllm/Dockerfile`. Build from the
inference repo root so Docker can read both the image files and patch directory:

```bash
DOCKER_BUILDKIT=1 docker build \
  -t mangchi-vllm:thor-qsa-fp8-5fd5dd5 \
  -f docker/mangchi-vllm/Dockerfile .
```

Do not build while a large model is resident. After rebuilding, restart the
residency agent so it reloads `etc/mangchi-agent.json`, then unload and reload
each affected model. Verify a streamed chat response contains partial
`prompt_progress`, cumulative `timings`, and final `timings`. The current patch
provides the live web UI metrics; `--enable-per-request-metrics` and
`--enable-prompt-tokens-details` retain vLLM's native final metrics and cached
token details.

Native DFlash canaries use
`/tmp/spec-analysis/bee-shallow/build/bin/llama-server`; with
`--cache-type-k turbo4`, set `GGML_DFLASH_GPU_RING=0`.
