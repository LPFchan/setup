# Plan: module dependencies in `setup`

**Status:** complete 2026-09-21 — A (`service-ctl` retirement), B (passage retirement), and C (the dependency feature).

## Goal

Let a module declare what it needs, so `setup` installs it in the right order and refuses to leave a dependent broken. Today that knowledge is scattered across eight hand-written special cases and five copies of the same resolver.

Two module retirements are folded in, because both remove edges the feature would otherwise have to encode. Shrink the graph first, then encode it.

## Decisions locked

| # | Decision |
|---|---|
| D1 | A missing dependency is installed automatically, and the install prints what it pulled in |
| D2 | `setup uninstall X` refuses while a dependent is installed. Non-interactive: refuse and exit non-zero. Interactive: warn and ask yes/no |
| D3 | Track "installed only as a dependency". On uninstalling the last dependent, offer to remove the orphan |
| D4 | No `optional` strength. `setup` → `fzf-multicolumn` keeps today's runtime fallback |
| D5 | Bare `setup install` enables service modules, matching the named case |
| D6 | `service-ctl` retires; `gpu-fancontrol` and `monitoring` own their own units |
| D7 | `passage` retires; OCI gets `CLOUDFLARE_API_TOKEN` in `~/.zshenv` instead |

## The graph

Real edges today, all currently implicit:

| Dependent | Needs | How it's expressed now |
|---|---|---|
| `providers`, `harnesses` | `auth` | hardcoded prepend in `cmd_install` (bin/setup:1032) + runtime raise |
| `backup`, `system-updates`, `kernel-simmer`, `providers`, `harnesses` | `schedule` | five separate `schedule_bin` / `_schedule_bin` resolvers |
| `gpu-fancontrol`, `monitoring` | `service-ctl` | nothing — enable just fails |
| `passage` | `auth` | runtime raise |

After D6 and D7: the `service-ctl` and `passage` rows disappear. What remains is `→ auth` (2) and `→ schedule` (5).

## Design

**Manifest.** A `requires` column on `manifest.tsv`, comma-separated module names. Empty means no dependencies.

**Resolution.** Topological sort before install. A cycle is a hard error naming the cycle, not a silent reorder.

**Visibility.** A module whose dependency is hidden by the audience or platform filter is itself hidden. An install that can never complete should not appear installable.

**Orphan tracking (D3).** A fourth column in `installed.tsv` recording whether the module was requested directly or pulled in. Script modules record the same in `script-state.tsv`.

## Implementation cost — revised during the work

The original plan was to widen the cached manifest to five columns and update
all eight read loops. **That plan was wrong and was abandoned.** The cached
manifest is a wire format between `setup` versions: a machine that has not
self-updated yet reads it with a four-field read, and a fifth column lands in
`source`, corrupting the payload URL of every module that declares a
dependency. The fleet self-updates overnight, so there is no moment where all
machines agree.

The column stays in the repository's `manifest.tsv`, but the cache is split:
the manifest cache keeps its four columns and dependencies go to a sibling
`requires.tsv`, the same shape `checksums.tsv` already uses. No read loop
changed, and old `setup` binaries simply ignore the new file.

Two bugs found while building it, both worth remembering:

- **Tab is IFS whitespace**, so a run of tabs collapses into one delimiter.
  Reading a six-field row whose fifth field is empty yields five fields and
  shifts `requires` into `mod_status`. The dependency cache is built with awk
  for that reason, not a shell `read`.
- **`${array[(Ie)value]}` reports a match's index**, and under `KSH_ARRAYS`
  the first element is index 0, which tests as false. `_list_contains` does
  the comparison directly. The hardcoded `auth` prepend had the same latent
  bug.

## Workstreams

### A — `service-ctl` retirement — DONE 2026-09-21

Rollout hazard, self-healing: a machine keeps routing enable/disable through
`service-ctl` until its own `~/.local/bin/setup` updates. Between the push and
that machine's nightly `setup schedule` run, `setup enable gpu-fancontrol`
fails with `sudo: service-ctl: command not found`. Running services are
unaffected — their units are already installed — and the next setup update
fixes it. Grimoire was updated by hand and verified.


Left behind: `module_service_unit` no longer returns `tool` for any module, so
the nine `!= tool` guards in `bin/setup` are unreachable. The mechanism still
has test coverage (`action-outcomes`, `explicit-command-outcomes`, both now on
synthetic fixtures). Removing it is its own slice — operator decision.


`service-ctl` writes units for `gpu-fancontrol` and `monitoring`. Its third component, `kernel-simmer`, is already pure pass-through (bin/service-ctl:147) and `setup enable kernel-simmer` bypasses it entirely.

1. Move unit install/remove into `gpu-fancontrol` and `monitoring`, each gaining its own `enable`/`disable`, matching `backup` and `system-updates`.
2. Repoint `module_enable_cmd` / `module_disable_cmd` (bin/setup:113).
3. Retire the `service-ctl` row, delete `bin/service-ctl`, drop it from `SERVICE_MODULES`.
4. Remove its README row.

### B — `passage` retirement — DONE 2026-09-21

Every consumer is one npm script line: `passage run --env CLOUDFLARE_API_TOKEN=infra/CF_MASTER_TOKEN -- <deploy>`. The module is installed on OCI only, and every consuming repo is checked out there. Order matters — deploys break if the module goes first.

1. Export `CLOUDFLARE_API_TOKEN` in OCI's `~/.zshenv`, **outside** the `# BEGIN setup:api-keys` markers (`_write_env_block` only rewrites between them, so a hand-added line survives the nightly sync). Distinct from `CLOUDFLARE_API_KEY`, which `providers` owns for the cloudflare inference provider.
2. Strip the wrapper prefix from eleven package.json scripts: `auth/gateway` (deploy + preflight), `auth/workers`, `agent-with-agent/workers`, `coverse` (deploy + migrate), `censor`, `tweet-fetch-mcp`, `joongna-mcp`, `bunjang-mcp`, `thinqconnect-mcp`, `okdam-songbook/apps/worker`, `2benches`.
3. Update `auth/gateway/test/preflight.test.ts:228`, which asserts the literal string.
4. `setup uninstall passage` on OCI.
5. Delete the manifest row, `files/passage`, `files/passage.sh`, `tests/passage-client.sh`, `tests/passage-lifecycle.sh`.
6. Update docs: setup README, `oci-cli/SKILL.md`, `lost-plus/references/registry.md`, `auth/deploy/RUNBOOK.md`, `agent-with-agent/records/OPERATIONS.md`, `okdam-songbook/docs/deployment.md`, `thinqconnect-mcp/README.md`, `tweet-fetch-mcp/README.md`.

### C — the dependency feature — DONE 2026-09-21

Declared edges: `providers → auth`, `harnesses → auth`, and `backup`,
`system-updates`, `kernel-simmer` → `schedule`. The five `schedule_bin`
resolvers stay — they answer "where is it", which the manifest does not — and
`providers`/`harnesses` keep theirs because their need for `schedule` is
Linux-only.

`setup → schedule` is deliberately not declared: `setup` works fully without
it apart from the optional `setup schedule` command, so its runtime message is
the right response. `backup` and friends cannot function at all without it.

Both hardcoded `auth` special cases are gone — the one in `cmd_install` and
the one in `cmd_update` that installed `auth` when `providers` or `harnesses`
was present. The update path now asks `installed_dependents_of` instead.

Covered by `tests/module-dependencies.sh`: ordering, duplicate requests,
cycles, a dependency outside the catalog, dependency marking, uninstall
refusal, the hidden-dependency prune, and an assertion that the cached
manifest is still four columns.

## Duplicates found while mapping this

Not in scope here, but recorded so they are not rediscovered:

| Job | Copies |
|---|---|
| Find the `schedule` binary | `bin/kernel-simmer:96`, `bin/backup:488`, `bin/system-updates:146`, `files/providers:89`, `files/harnesses:1312` |
| POST to the passage MCP | `files/providers:390`, `files/harnesses:305` (third copy dies with workstream B) |
| Get a token from the `auth` CLI | `files/providers:221`, `files/harnesses:186` |

The `schedule` resolvers differ only in comments. The other two pairs are the same logic written longhand in one file and compressed in the other.
