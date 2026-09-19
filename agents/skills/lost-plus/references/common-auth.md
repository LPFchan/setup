# Common Auth

`auth.lost.plus` owns accounts, browser sessions, machine tokens, MCP OAuth,
roles, service visibility, and admission. It is a Cloudflare Worker
(`auth-lost-plus`) over a D1 database, from `LPFchan/auth` (`workers/`).

Services never validate a credential themselves. A **gateway** authenticates
each request against the hub and forwards a trusted identity to the service.
There are two gateway kinds, both from `LPFchan/auth`, both implementing the
same contract:

| Gateway | Runs | Fronts | Reaches the hub via | Reaches the service via |
| --- | --- | --- | --- | --- |
| cloud gateway (`auth-gateway` Worker, `gateway/`) | Cloudflare | services hosted on Workers | `AUTH_HUB` service binding | a service binding per service |
| local gateway (Rust `auth-gateway`, `src/bin/`) | one process per machine, `127.0.0.1:8740` | services hosted on that machine | HTTPS to `auth.lost.plus` | loopback upstream URL |

A service is fronted by the gateway of the place it runs. A Workers service
never calls a machine gateway; a machine service never calls the cloud
gateway. Services that were behind a gateway stay behind one when they move.

Which gateway fronts which hostname is in [registry](registry.md).

## Route policies

Every route has one explicit policy:

| Policy | Credential | Surface | Failure |
| --- | --- | --- | --- |
| `public` | none | deliberately public page or API | backend response |
| `oauth` | browser session | browser app and same-origin API | navigation redirects; API request `401` |
| `api` | machine token or browser session | script/browser HTTP API | `401`; hub outage `503` |
| `mcp` | scoped machine token or resource-bound OAuth token | Streamable HTTP MCP | OAuth-aware `401`; hub outage `503` |

`oauth` rejects machine credentials. Only unsigned GET/HEAD browser
navigations redirect; API-style requests get `401`.

`public` applies to the entire matched path. Use narrow matchers for public
reads and protected writes. The gateway canonicalizes paths before matching
and rejects encoded slash or backslash. Routes match longest `path_prefix`
first; a hostname the gateway holds but no route matches gets a gateway `404`.

`allow_anonymous: true` on an `mcp` route lets missing credentials through for
intentionally public tools; an invalid explicit credential still fails.

## Identity and admission

- Browsers use the secure, HTTP-only `lp_auth` cookie. API clients use
  `Authorization: Bearer` or `X-API-Key`. MCP OAuth uses discovery,
  authorization code with PKCE S256, and resource-bound tokens.
- An explicit credential is authoritative. Invalid, revoked, wrongly scoped, or
  ineligible credentials return `401` with no cookie or anonymous fallback.
- The hub enforces service visibility and `admin_only`. Authorization-data
  errors fail closed. The gateway accepts the hub's admission result.
- Use immutable `sub`, preferably `auth.lost.plus:<sub>`, for private records,
  idempotency, settings, caches, and queued work. Email and display name are
  presentation fields. Display names fall back to normalized email and contain
  at most 80 Unicode scalar values.
- Visibility keys and machine-token scopes are separate namespaces. The
  gateway sends `audience=<visibility-key>` and `service=<token-scope>`.

## Backend boundary

The gateway removes credentials, `lp_auth`, proxy and connection-nominated
headers, and client-supplied `x-lost-plus-*` headers. MCP receives no cookies.
Authenticated requests receive percent-encoded UTF-8 identity headers:

```text
X-Lost-Plus-Encoding: percent-utf8
X-Lost-Plus-Sub: <immutable account id>
X-Lost-Plus-Email: <email>
X-Lost-Plus-Name: <display name>
X-Lost-Plus-Role: <administrator|user>
```

Everything outside `A-Z a-z 0-9 * - . _` is percent-encoded; a space arrives
as `%20`, never `+`. Decode with `decodeURIComponent`. Require the encoding
header; treat a missing, empty, or undecodable field as "no identity", and
refuse rather than guess.

Do not write that decoder again. Use the shared package, pinned to a tag:

```json
"@lost-plus/gateway-identity": "github:LPFchan/gateway-identity#v1.0.0"
```

`identityFrom(headers)` returns `{ sub, email, name, role }` or `null` with
exactly the rules above; `identityFrom(headers, { maxNameLength: 80, roles:
["administrator", "user"] })` adds the two restrictions some services want;
`requireIdentity(headers)` throws an `IdentityError` (status 500) instead of
returning `null`. The package decodes headers and never validates a credential
(LPFchan/auth DEC-20260919-003). It is only safe to call where the trust rule
below holds.

Where a service may trust those headers:

- **Workers service**: only when invoked through the gateway's service
  binding. Declare **no zone route** of your own (`workers_dev = false`, no
  `routes`); the gateway holds the hostname. A Worker with its own route that
  reads these headers can be spoofed by anyone on the internet.
- **Machine service**: only on a private loopback port behind the local
  gateway. Bind a standalone service to loopback; containers may listen
  internally on `0.0.0.0` when Docker publishes the host port on `127.0.0.1`.

Never send `Authorization` to the service: the gateway strips it under every
policy, `public` included, so a backend that checks its own token sees an
anonymous request. Never `fetch("https://auth.lost.plus/…")` from a Worker: a
Worker's request to a hostname in its own zone skips that zone's Worker routes
and goes to the origin, not the hub.

Cookie-authenticated mutations and OAuth WebSocket handshakes require the exact
service origin. Interactive HTML denies framing with CSP `frame-ancestors
'none'` and `X-Frame-Options: DENY`.

Treat browser-cached identity as display state. Before private reads or writes,
refresh the session and verify the expected `sub`. Bind drafts, asynchronous
results, and queued writes to that subject; discard or quarantine them after an
account switch.

## WebSockets and other bypasses

The cloud gateway does not proxy WebSocket upgrades. A Workers service that
needs one serves it on a **direct zone route** of its own for that path only,
authorizes it by capability (a room token in the URL, checked by the service)
rather than by identity headers, and keeps every identity-bearing path behind
the gateway. The Worker must partition the two: the default entrypoint serves
the direct paths and must ignore `x-lost-plus-*`; the gateway-facing
entrypoint (a named export the binding targets) serves the rest. Record such
splits in the service's records and in [registry](registry.md).

## MCP

- Servers hosted on Workers use `@modelcontextprotocol/server@^2.0.0`
  (`McpServer` + the fetch handler), never the legacy
  `@modelcontextprotocol/sdk`.
- Set `cacheHints: { 'tools/list': { ttlMs: 300_000, cacheScope: 'private' } }`
  in the `McpServer` options so 2026-07-28 clients cache the tool list for
  five minutes. Use `public` only when the list is identical for every caller.
- The gateway owns `GET`/`HEAD /healthz`, CORS preflight, the OAuth `401`
  challenge, and `/.well-known/oauth-protected-resource/mcp` for the exact
  canonical `https://<host>/mcp` resource and its scope. The server does not
  serve those itself.
- Register the token scope in the hub's service registry even when it is
  hidden from the Apps page.
- Anonymous backends enforce streaming body limits, absolute read timeouts, and
  bounded in-flight work. Cancellation releases capacity after tool work ends.

## Adoption

Decide first where the service runs; that decides the gateway.

1. Choose the hostname, longest `path_prefix`, methods, policy, visibility key,
   token scope. `oauth` needs visibility, `mcp` needs a scope, and `api` needs
   both. Register the keys on the hub (Apps page or `services` table).
2. **Workers**: add the route to `gateway/config/cloudflare.gateway.json` with
   a `binding`, add the matching `[[services]]` binding in
   `gateway/wrangler.toml`, and add the `<host>/*` pattern to the gateway's
   `routes` list there. All three together: a route naming an undeclared
   binding makes the gateway refuse every request, and a deploy replaces the
   Worker's whole route set with exactly that list, silently dropping any
   pattern added by hand. Deploy with `npm run deploy` in `gateway/` (it
   validates the table; plain `wrangler deploy` ships no table and answers
   `503`). If the service Worker already holds the pattern, move it with the
   Cloudflare API first; wrangler refuses a pattern another Worker holds.
   Point the hostname's DNS at a proxied placeholder (`A 192.0.2.1` or
   `AAAA 100::`), not at a tunnel.
   **Machine**: add the route with an `upstream` to
   `deploy/<machine>/gateway.json`, install it at `/etc/auth/gateway.json`,
   restart `auth-gateway.service`, and route the hostname's tunnel ingress to
   `127.0.0.1:8740`.
3. Let the service read the identity headers and enforce its own domain
   authorization (record ownership, tool permissions). Point browser logout
   to `/_auth/logout`.
4. Update the service records, the hub inventory, the MCP registry in
   `LPFchan/setup` (`files/harnesses-manifest.json`), and
   [registry](registry.md) together.

Keep secrets out of configuration, documentation, commits, logs, and review
prompts. Worker secrets go in `wrangler secret`, never `[vars]`.

## Rollback and recovery

- Hub: D1 Time Travel (30-day retention). Reading a bookmark and the restore
  call are in `deploy/RUNBOOK.md` in `LPFchan/auth`. There is no warm standby,
  Litestream, or restic copy of the account database any more.
- Cloud gateway: `wrangler rollback` for the code; for a single service, remove
  its routes from `cloudflare.gateway.json` and redeploy, or move the zone
  route back to the service Worker with the API.
- Local gateway: the previous image tag in `auth-gateway.service`'s
  `ExecStart`; config backups sit next to `/etc/auth/gateway.json`.

## Verification

Run the affected repositories' full checks, then verify the deployed set from
the public internet:

- public, unsigned, allowed, restricted, invalid, and hub-unavailable requests
  reach the expected response and backend boundary
- spoofed identity, proxy, cookie, and connection headers are stripped
- identity encoding preserves spaces, plus signs, Unicode, blank-name fallback,
  and the 80-character limit
- same-origin mutations succeed; cross-origin and wrong-subject work fails
- account switching cannot transfer private reads, writes, drafts, queues,
  favorites, or idempotency state
- MCP discovery, challenge, registration, PKCE, refresh, revocation, health,
  preflight, scope mismatch, optional anonymous access, initialization, and
  the `tools/list` cache hint work
- global and per-service machine-token modes enforce their registered scopes
- `/_auth/logout` invalidates the server session and expires the cookie

Record the deployed hub, gateway, and service commits. Smoke-test production
after the coordinated rollout is complete.
