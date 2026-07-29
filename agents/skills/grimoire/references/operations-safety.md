# Operations and Safety

## Incident Snapshot

```bash
systemctl status grimoire.service --no-pager
systemctl cat grimoire.service
/usr/bin/docker ps --filter name=^/grimoire$
/usr/bin/docker logs --tail 200 grimoire
nvidia-smi
```

| Evidence | Proves |
| --- | --- |
| systemd active | Compose transition completed |
| container healthy or `/health` | A proxy worker answers |
| authenticated `/status` | Manager and reported subprocess state |
| inference smoke | Model capability works |

Use `journalctl -u grimoire.service` for unit/Compose lifecycle and
`docker logs` for gateway/backends. Do not `docker compose down` while
diagnosing.

## Persistence

- `state/`: registry, presets, history, usage, cache metadata.
- `/home/yeowool/models`: external, container-writable model files.
- `/dev/shm/grimoire-*`: ephemeral.
- Processes/VRAM: ephemeral; active preset: restored on boot.
- History: keyed by API-key identity hash; changing keys changes its namespace.

## Fast Diagnosis

| Symptom | First check | Likely cause |
| --- | --- | --- |
| `/health` works; management fails | `/status`, manager logs | Proxy alive; manager down |
| Listed model fails | `active`, `status`, preset | Catalog includes unloaded models |
| switch/stop 409 | Active preset | Preset lock |
| preset 200, incomplete | `failed`, `warnings`, `/status` | Partial activation |
| Registry rollback | Seed/state mtimes and diff | Newer seed won |
| LoRA/control-token regression after build | Patch args and token smoke | Patch-policy mismatch |
| Exclusive model OOM | Budgets, `nvidia-smi` | Co-location with budgeted tenants |
| UI change absent | Submodule HEAD, build, bind, cache | Host build stale |
| Python change absent | Bind, process start time | Process not restarted |

## Destructive Boundaries

Registry deletion can remove shared GGUF/adapter files. Resolve all references,
preserve manifests, distinguish shared bases/mmproj, obtain explicit file-delete
authorization, and remove the alias first. Never use `force` to bypass a
shared-file warning. Unload; never delete to free VRAM.

Check the active preset and `nvidia-smi` before claiming GPUs shared with
ComfyUI or Eastself.

Port `9001` binds all interfaces. Admin auth falls back to the API key;
registry writes/uploads/deletes currently accept API auth. Treat all as
administrative.

`/cors-proxy` accepts arbitrary targets and forwarded headers without explicit
route auth. Treat it as an SSRF/open-proxy boundary; never use it for general
fetching or forward credentials through it.
