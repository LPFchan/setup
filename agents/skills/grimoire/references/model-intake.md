# Model and LoRA Intake

## Registry Authority

| Item | Path |
| --- | --- |
| Host models | `/home/yeowool/models` |
| Container models | `/models` |
| Live registry | `state/models.json` |
| Tracked seed | `etc/models.json` |

The newer registry file wins at startup; a newer seed can overwrite live state.
The `state/` bind follows atomic replacements; the seed file bind may retain an
old inode until container recreation.

Before intake or recreation:

```bash
jq '.models | length' etc/models.json state/models.json
diff -u <(jq -S . etc/models.json) <(jq -S . state/models.json)
```

Mutate live state through the API, then reconcile accepted entries into the seed
without losing concurrent entries.

`PUT /registry/model/{alias}` merges; omitted keys remain. Read back the entry.
Use an explicitly reviewed full-registry edit to remove stale keys.

## GGUF Intake

1. Verify source, license, checksum, architecture, tokenizer/template, mmproj,
   disk, and VRAM.
2. Store under `/home/yeowool/models/gguf/`; `/models` is writable.
3. Copy only justified settings from a compatible accepted model: capability,
   limits, parallelism, cache, GPU layers, family defaults, costs, mmproj,
   speculation, and VRAM budget.
4. Prefer the Models UI or `/registry/ingest-start`,
   `/registry/ingest-configure`, and `/registry/ingest-status/{task}` for
   Hugging Face URLs. Upload with `/registry/upload`; finalize with
   `PUT /registry/model/{alias}`.
5. Read back the entry and `/v1/models`; load outside a conflicting preset.
6. Smoke the claimed capability; inspect command/logs, VRAM, context, and output;
   unload unless residency is intended.
7. Reconcile accepted config into `etc/models.json`.

Legacy `/ingest` and `grimoire ingest` create minimal configs, not production
entries. Validate conservative TurboQuant K/V settings before stronger
compression on a new model family.

Managed downloads are HTTPS-only, reject private/non-routable targets, cap at
80 GiB, and do not resume. Uploads cap at 40 GiB. Ingest task state disappears
on gateway restart.

## PEFT/LoRA Intake

Canonical entrypoint: `scripts/intake-peft-checkpoint.py`.
Read `records/decisions/DEC-20260703-001-training-checkpoint-intake.md` and
`/home/yeowool/Eastself/guides/bprime-v1-regeneration-to-launch.md`.

The script produces an adapter GGUF, a tokenizer-aligned base GGUF using exact
`trainable_token_indices`, a provenance manifest, and an optional minimal
`--lora` registry entry.

Dry-run first:

```bash
cd /home/yeowool/grimoire
.venv/bin/python scripts/intake-peft-checkpoint.py \
  --checkpoint /home/yeowool/models/WORK/checkpoint-N \
  --base-gguf /home/yeowool/models/gguf/BASE.gguf \
  --base-hf /home/yeowool/models/base-hf/BASE \
  --model-alias MODEL_ALIAS \
  --ctx-size VERIFIED_CONTEXT \
  --outtype f16 \
  --dry-run
```

Then remove `--dry-run`. Add `--update-registry` only after reviewing current
state and the printed config. Keep explicit `--outtype f16`; provide
`--base-hf` when checkpoint metadata contains a stale training-host path.

- Do not run conversion under `sudo`.
- Merge justified serving fields into the script's minimal registry entry.
- Keep `.intake.json`; it hashes inputs, so hash outputs separately.
- Tokenizer rewriting copies the base GGUF; reuse verified aligned outputs.
- Registry changes require unload/reload or preset re-activation.
- Verify effective patch mode and control-token behavior before launch.
- `POST /alpha` changes only an active LoRA backend; resolve exactly one model
  or name it, then verify with `GET /alpha`.

A successful load is not acceptance; require representative output and
applicable tokenizer/control-token checks before reconciling the seed.
