# Service registry

Every `lost.plus` hostname, what answers it, where that runs, and which
gateway (if any) sits in front. Update this table in the same change that
moves, adds, or retires a service. The `fleet` skill describes the machines;
this file describes the services.

"Gateway" values: `cloud` = the `auth-gateway` Worker; `oci` / `grimoire` =
that machine's local Rust gateway on `127.0.0.1:8740`; `none` = reached
directly, no Common Auth.

## Cloudflare Workers

DNS for these is a proxied placeholder record (`A 192.0.2.1`); the zone route
`<host>/*` on the gateway answers, and a path the route table does not name
gets a gateway 404. MCP hosts route only `/mcp`.
Deploy with `wrangler` from the repo (token `CF_MASTER_TOKEN` in passage,
folder `infra`; account `f6f0cfde…`). Each repo's `npm run deploy` fetches it
at deploy time via the `passage` setup module:
`passage run --env CLOUDFLARE_API_TOKEN=infra/CF_MASTER_TOKEN -- npx wrangler deploy`.

| Hostname | Service | Worker · state | Gateway · policy | Repo |
| --- | --- | --- | --- | --- |
| `auth.lost.plus` | Common Auth hub | `auth-lost-plus` · D1 `auth` | none (it is the hub) | `LPFchan/auth` `workers/` |
| `awa.lost.plus` | agent-with-agent chatrooms | `awa` · Durable Objects | cloud · `/` oauth, `/api/manage` api (scope `awa-v1`); direct routes `/api/rooms/*` (WebSocket), `/r/*`, `/assets/*`, `/skill.md`, `/icon.svg`, `/healthz` | `LPFchan/agent-with-agent` |
| `okdam.lost.plus` | Songbook | `okdam-songbook` · D1 `okdam-songbook` | cloud · `/` public, `/api/catalog` public GET, `/api` oauth, `/mcp` mcp (scope `okdam-mcp`) | `LPFchan/okdam-songbook` |
| `coverse.lost.plus` | Coverse | `coverse` | cloud · `/` public, `/api/project` + `PUT /api/draft` oauth | `LPFchan/coverse` |
| `censor.lost.plus` | Censor PWA + MCP | `censor` · static assets | cloud · `/` public, `/mcp` mcp anonymous-allowed (scope `censor`) | `LPFchan/censor` |
| `tweet.lost.plus` | tweet-fetch MCP | `tweet-fetch` | cloud · `/mcp` mcp (scope `tweet-fetch`) | `LPFchan/tweet-fetch-mcp` |
| `joongna.lost.plus` | 중고나라 search MCP | `joongna-mcp` | cloud · `/mcp` mcp (scope `joongna`) | `LPFchan/joongna-mcp` |
| `bunjang.lost.plus` | 번개장터 search MCP | `bunjang` | cloud · `/mcp` mcp (scope `bunjang`) | `LPFchan/bunjang-mcp` |
| `thinq.lost.plus` | LG ThinQ appliance MCP | `thinqconnect` | cloud · `/mcp` mcp (scope `thinqconnect`) | `LPFchan/thinqconnect-mcp` |

The cloud gateway's route table is `gateway/config/cloudflare.gateway.json`
and its bindings and zone routes are `gateway/wrangler.toml`, both in
`LPFchan/auth`. Those two files are the source of truth for this section.

## oci-ubuntu (Oracle Cloud VPS)

Reached through the `obsidian-sync` Cloudflare tunnel (`/etc/cloudflared/
config.yml` on the box). Gateway config: `deploy/oci/gateway.json` in
`LPFchan/auth`, installed at `/etc/auth/gateway.json`.

| Hostname | Service | Runs as · port | Gateway · policy | Repo |
| --- | --- | --- | --- | --- |
| `mcp.lost.plus` | Obsidian vault MCP | container `mcp` · `127.0.0.1:3000` | oci · mcp (scope `obsidian`) | `~/mcp` |
| `passage.lost.plus` | passage secrets MCP | container `passage-mcp` · `:8002` | oci · mcp (scope `passage`) | `~/passage-mcp` |
| `onedrive.lost.plus` | OneDrive / M365 MCP | container `onedrive-mcp` · `:8005` | oci · mcp (scope `onedrive`) | `~/onedrive-mcp` |
| `marble.lost.plus` | Marble (Obsidian web) | container `marble-marble-1` · `:3002` | oci · oauth (visibility `marble`) | `~/Marble` |
| `lost.plus` | homepage | caddy · `:8400` | none | `~/lost.plus` |
| `artmu.lost.plus` | artmu-bench site | container · `:8080` | none | `~/artmu-bench-site` |
| `photopeace.lost.plus` | Photopeace | nginx container · `:8082` | none | `~/photopeace` |
| `upstream.lost.plus` | upstream fork tracker | `upstream.service` · `:8620` | none | `~/upstream` |

## grimoire (dual-RTX 3090 box)

Reached through the `grimoire` Cloudflare tunnel. Gateway config:
`deploy/grimoire/gateway.json` in `LPFchan/auth`.

| Hostname | Service | Gateway · policy | Where |
| --- | --- | --- | --- |
| `comfy.lost.plus` | ComfyUI MCP (`:9100`) | grimoire · mcp (scope `comfyui`); ingress is the OCI tunnel → Grimoire Tailscale Serve | `inference` skill |
| `muum.lost.plus` | Muum (`:8779`) | grimoire · oauth (visibility `muum`) | `~/muum` |
| `chat.lost.plus` | OpenAI-compatible inference API | none (own key) | `~/inference`, `inference` skill |
| `dash.lost.plus` | inference telemetry dashboard | none | `~/inference` |
| `heatmap.lost.plus` | heatmap + MCP | none | `~/heatmap` |
| `eastself.lost.plus` | eastself | none | `~/Eastself` |
| `librechat.lost.plus`, `webui.lost.plus`, `unsloth.lost.plus` | tunnel entries on Grimoire | none | check the box before relying on them |

## Elsewhere

| Hostname | What |
| --- | --- |
| `setup.lost.plus` | GitHub Pages for `LPFchan/setup` |
| `homebridge.lost.plus`, `unifi.lost.plus`, `*.lost.plus` (wildcard `A 10.0.0.50`) | LAN-only, bingus |
| `oci.lost.plus`, `grimoire.lost.plus`, `mangchi.lost.plus`, `mac.lost.plus` | machine addresses, see `fleet` |

## Not answering (decide: revive or delete the record)

| Hostname | State on 2026-09-19 |
| --- | --- |
| `gsw.lost.plus` | 502 — tunnel entry to `:8500` on OCI still present, nothing listens; repo `~/gswtools` last touched 2026-08-27 |
| `soma.lost.plus` | 522 — `A` record to the OCI public IP, nothing on 80/443 |
| `deepest.lost.plus` | 530 — tunnel `deepest-crawl` is down |

## Hub registry rows with no gateway route yet

`chat.lost.plus` / `chat-v1`, `grimoire-v1`, `eastself.lost.plus` are
registered on the hub but no gateway references them (pending adoptions).

## MCP client registry

The harnesses read the hub: `files/harnesses` in `LPFchan/setup` calls
`GET /api/services` and enrolls every admitted registry row with an
`mcp_url`, using its `token_key` as the Common Auth scope (a row with an
`mcp_url` and no `token_key` enrolls as an anonymous MCP). A lost.plus MCP
goes live for every harness by getting its hub row right; nothing is added
by hand in setup. Only third-party MCPs (jina, exa, korean-law, daiso,
notion, heatmap) are listed by hand, in `files/harnesses-manifest.json`
(`mcpServers`).
