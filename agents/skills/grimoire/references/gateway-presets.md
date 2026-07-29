# Gateway, Presets, and Lifecycle

## Gateway

- Stateful manager: `127.0.0.1:9000`.
- Public proxy workers: port `9001`.
- Proxy-served routes: `/v1/embeddings`, `/v1/rerank`, `/v1/reranking`.
- All other public routes forward to the manager.
- GPU backends start at port `8001`; CPU backends at `8500`.
- OpenAI clients use `<origin>/v1`; management uses `<origin>/...`.

The split keeps lifecycle/chat in one state owner while proxy workers scale encoder traffic.

| Route | Meaning | Auth |
| --- | --- | --- |
| `GET /health` | Proxy liveness only | none |
| `GET /v1/models` | Registry plus active/status metadata | API |
| `GET /status` | Processes, ports, GPUs, fixed map | API |
| `GET /models` | Registry plus active/fixed summary | API |
| `POST /switch/{model}` | Load model | admin |
| `POST /stop/{model}` | Stop model | admin |
| `POST /models/load`, `/models/unload` | Webui lifecycle aliases | admin |
| `POST /models/{name}/clone`, `/declone` | Temporarily shard one process across GPUs, or clear that sharding | admin |
| `POST /models/{name}/pin`, `/unpin` | Temporarily set or suppress eviction protection | admin |
| `GET /registry/model/{name}` | Effective config | API |
| `PUT /registry/model/{name}` | Merge/upsert config | API today; treat as admin |
| `GET /presets[/name]` | Inspect presets | API |
| `PUT /presets/{name}` | Save definition | admin |
| `DELETE /presets/{name}` | Delete definition | admin |
| `POST /presets/{name}/activate` | Reconcile definition | admin |

`/v1/models` includes unloaded models; check `active` and `status.value`.
Chat, embedding, rerank, and `/props` may cold-load; inspect with `/props?model=ALIAS&autoload=false`.

## Presets

A gateway preset is a saved workload topology in host `state/presets.json` (container `/var/lib/grimoire/presets.json`):

| Field | Meaning |
| --- | --- |
| `models` | Required resident aliases |
| `fixed` | Replacement model→GPU pin map |
| `gpus` | Optional allowed-GPU mask |
| `description` | Intent |

It is unrelated to webui system-prompt presets. `free` releases manual control;
`single-gpu` keeps Grimoire off GPU 1; `embed-rerank` locks retrieval
replicas; `eastself` locks chat/retrieval to GPU 0. Query `/presets/{name}`
for current aliases and pins.

## Switching vs Modifying

| Operation | Examples | Contract |
| --- | --- | --- |
| **Reversible switch** | `POST /presets/{name}/activate` | Applies an existing definition; may stop/start models but does not edit the preset |
| **Irreversible modification** | `PUT`/`DELETE /presets/{name}`; edit/delete `state/presets.json`, `src/grimoire/presets.py`, or `src/grimoire/routes/presets.py` | Changes the definition or implementation; switching cannot undo it |

A request to switch, activate, or use a preset authorizes only the reversible
operation. Never edit/delete those files without explicit request and exact-diff approval.

Before an irreversible modification:

1. Show the exact definition/code change and obtain explicit approval.
2. Ask whether to update `~/setup/agents/skills/grimoire/` references in the
   same change.

Prefer the API after approval; direct JSON/Python edits require specific approval.
Saving does not apply a preset; activation is a separate reversible operation.

## Activation

| Shape | Immediate effect | Manual control |
| --- | --- | --- |
| Any `models` or `fixed` | Replace fixed map/mask; stop non-target or moved models; start targets | locked |
| No models/fixed, with `gpus` | Stop all; clear fixed map; retain mask | allowed inside mask |
| No models/fixed/mask (`free`) | Stop all; clear lock/mask; restore pre-preset fixed map | allowed |

Before activation, compare the preset with `/status`, name the stop/start set,
and never activate merely to inspect.

Activation is non-transactional: HTTP 200 may contain `failed` and `warnings`;
partial changes may remain active. Re-activation repairs missing targets, pins,
masks, and manual-control drift.

A locked preset allows requests to running targets but rejects cold loads and
manual stops. Activate another preset before deleting the active one.

Runtime clone/pin overrides live only in manager memory, never edit registry or
preset state, and clear on restart. `clone` means one sharded llama-server
process, not a replica. `/status` reports `gpu`/`gpus` as actual residency and
requested placement plus placement/pin sources separately. Locked preset
activation clears all overrides and reloads affected target models; manual-control
presets retain overrides while enforcing their GPU mask.

The active preset and pre-preset fixed map survive restart. Failed restore falls
back to the initial model plus entries with `always-on: true` and boolean
`cpu-only`; arbitrary previously active models are not restored.

## Allocation

- `fixed` sets placement and eviction protection, not residency; outside a
  locked preset, admin stop still works.
- Positive `vram-budget-mib` makes a model co-locatable; allocation checks free
  VRAM and may evict all non-fixed incumbents on a candidate GPU.
- Unbudgeted models prefer an empty GPU, then replace the oldest non-fixed
  exclusive, then co-locate with budgeted-only tenants without a VRAM pre-check.
  Bad sizing can OOM.
- Failed startup attempts to restore evicted incumbents; verify rollback.
- A preset GPU mask can invalidate a registry pin.
