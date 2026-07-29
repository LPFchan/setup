# Gateway, Presets, and Lifecycle

## Gateway

- Stateful manager: `127.0.0.1:9000`.
- Public proxy workers: port `9001`.
- Proxy-served routes: `/v1/embeddings`, `/v1/rerank`, `/v1/reranking`.
- All other public routes forward to the manager.
- GPU backends start at port `8001`; CPU backends at `8500`.
- OpenAI clients use `<origin>/v1`; management uses `<origin>/...`.

The split keeps lifecycle/chat in one state owner while proxy workers scale
encoder traffic across replicas.

| Route | Meaning | Auth |
| --- | --- | --- |
| `GET /health` | Proxy liveness only | none |
| `GET /v1/models` | Registry plus active/status metadata | API |
| `GET /status` | Processes, ports, GPUs, fixed map | API |
| `GET /models` | Registry plus active/fixed summary | API |
| `POST /switch/{model}` | Load model | admin |
| `POST /stop/{model}` | Stop model | admin |
| `POST /models/load`, `/models/unload` | Webui lifecycle aliases | admin |
| `GET /registry/model/{name}` | Effective config | API |
| `PUT /registry/model/{name}` | Merge/upsert config | API today; treat as admin |
| `GET /presets[/name]` | Inspect presets | API |
| `PUT /presets/{name}` | Save definition | admin |
| `POST /presets/{name}/activate` | Reconcile definition | admin |

`/v1/models` includes unloaded models; check `active` and `status.value`.

Chat, embedding, rerank, and `/props?model=...` may cold-load and evict. Read
metadata without loading via `/props?model=ALIAS&autoload=false`.

## Presets

A gateway preset is a saved workload topology in host `state/presets.json`
(container `/var/lib/grimoire/presets.json`):

| Field | Meaning |
| --- | --- |
| `models` | Required resident aliases |
| `fixed` | Replacement model→GPU pin map |
| `gpus` | Optional allowed-GPU mask |
| `description` | Intent |

It is unrelated to webui system-prompt presets.

Current intents: `free` releases manual control; `single-gpu` keeps Grimoire
off GPU 1; `embed-rerank` locks retrieval replicas; `eastself` locks
chat/retrieval to GPU 0. Query `/presets/{name}` for current aliases and pins.

Edit a preset only when its topology changes. Activate it to switch workloads or
reconcile drift. Saving an active preset does not apply it; activate again.

## Activation

| Shape | Immediate effect | Manual control |
| --- | --- | --- |
| Any `models` or `fixed` | Replace fixed map/mask; stop non-target or moved models; start targets | locked |
| No models/fixed, with `gpus` | Stop all; clear fixed map; retain mask | allowed inside mask |
| No models/fixed/mask (`free`) | Stop all; clear lock/mask; restore pre-preset fixed map | allowed |

Before activation, compare the preset with `/status` and name the stop/start set.

Activation is non-transactional: HTTP 200 may contain `failed` and `warnings`,
and partial changes may remain active. Re-activation repairs missing targets,
pins, masks, and manual-control drift.

A locked preset allows requests to running targets but rejects cold loads and
manual stops. Activate another preset before deleting the active one.

The active preset and pre-preset fixed map survive restart and are reconciled on
boot. If restore fails, Grimoire clears it and falls back to the initial model
plus entries having both `always-on: true` and an explicit boolean `cpu-only`.
Without a preset, arbitrary previously active models are not restored.

## Allocation

- `fixed` sets placement and eviction protection, not residency; outside a
  locked preset, admin stop still works.
- Positive `vram-budget-mib` makes a model co-locatable; allocation checks free
  VRAM and may evict all non-fixed incumbents on a candidate GPU.
- Unbudgeted models are exclusive relative to other unbudgeted models: prefer an
  empty GPU, else replace the oldest non-fixed exclusive, else co-locate with
  budgeted-only tenants without a VRAM pre-check. Bad sizing can OOM.
- Failed startup attempts to restore evicted incumbents; verify rollback.
- A preset GPU mask can invalidate a registry pin.

```bash
GRIMOIRE_ORIGIN=http://localhost:9001
GRIMOIRE_CONTROL_TOKEN=${GRIMOIRE_ADMIN_TOKEN:-$GRIMOIRE_API_KEY}

curl -fsS -H "Authorization: Bearer $GRIMOIRE_API_KEY" \
  "$GRIMOIRE_ORIGIN/presets/single-gpu" | jq
curl -fsS -X POST -H "Authorization: Bearer $GRIMOIRE_CONTROL_TOKEN" \
  "$GRIMOIRE_ORIGIN/presets/single-gpu/activate" | jq
```

Never load or activate merely to inspect.
