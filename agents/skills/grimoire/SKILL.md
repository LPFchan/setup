---
name: grimoire
version: 1.0
description: "Operate and develop the fleet-only Grimoire multi-GPU inference system. Use whenever work involves the grimoire host, chat.lost.plus, /home/yeowool/grimoire, gateway or OpenAI-compatible endpoints, model loading and eviction, presets, the model registry, GGUF/PEFT/LoRA intake, the forked llama.cpp webui, the TurboQuant backend, ComfyUI or its MCP companion, deployment, GPU allocation, or inference incidents."
argument-hint: "Operational task, model/preset name, or incident"
audience: fleet
---

# Grimoire

## Before Work

1. Load `fleet`; use its SSH/tmux procedure unless already on `grimoire`.
2. Read `/home/yeowool/grimoire/AGENTS.md`; preserve dirty worktrees.
3. Trust, in order: live authenticated service and installed unit; current
   code/config/state; accepted repo records.
4. Resolve contradictions before rebuilding or mutating state.

| Use | URL |
| --- | --- |
| Local origin | `http://localhost:9001` |
| Remote origin | `https://chat.lost.plus` |
| OpenAI base | `<origin>/v1` |
| Internal manager | `127.0.0.1:9000`; never use as a client endpoint |

Use `vaultwarden_secrets.get_secret({"folder":"llm","item_name":"GRIMOIRE_API_KEY"})`; never print or persist it.

```bash
GRIMOIRE_ORIGIN=http://localhost:9001
curl -fsS "$GRIMOIRE_ORIGIN/health"
curl -fsS -H "Authorization: Bearer $GRIMOIRE_API_KEY" "$GRIMOIRE_ORIGIN/status" | jq
curl -fsS -H "Authorization: Bearer $GRIMOIRE_API_KEY" "$GRIMOIRE_ORIGIN/v1/models" | jq
curl -fsS -H "Authorization: Bearer $GRIMOIRE_API_KEY" "$GRIMOIRE_ORIGIN/presets" | jq
```

`/health` proves only a proxy worker; `/status` proves the manager.

## Open the Right Reference

| When the task involves… | Read |
| --- | --- |
| Client URLs, model discovery, load/unload/switch behavior, GPU placement or eviction, preset creation/activation, or predicting which models stop/start | [gateway-presets.md](references/gateway-presets.md) |
| Adding, replacing, deleting, or accepting a GGUF, Hugging Face model, checkpoint, adapter, or LoRA; syncing live and tracked registries | [model-intake.md](references/model-intake.md) |
| Runtime ownership, the webui/engine split, fork/upstream differences, DFlash canaries, Python gateway edits, webui/engine updates, or Docker/Compose/systemd changes | [architecture-upgrades.md](references/architecture-upgrades.md) |
| ComfyUI service/UI, image models/workflows/custom nodes, GPU 1 co-tenancy, or the ComfyUI MCP tunnel | [comfyui.md](references/comfyui.md) |
| Incident triage, logs/health disagreement, restart persistence, shared storage, deletion risk, credentials, or exposed routes | [operations-safety.md](references/operations-safety.md) |

Open every matching row.

## Before Any Mutation

1. Capture preset, status, fixed map, GPU state, and worktree state.
2. Predict stops, starts, moves, and locks.
3. Change the owning layer only.
4. Verify response body, `/status`, GPU/process state, and logs.
5. Reconcile accepted live config into its tracked source without losing
   concurrent entries.

Never use `docker commit`, `docker compose down -v`, direct backend kills, or
file deletion as a first response.
