# Common Auth

`auth.lost.plus` owns accounts, browser sessions, machine tokens, MCP OAuth,
roles, service visibility, and admission. Each backend machine runs a stateless
gateway that authenticates requests and forwards trusted identity to private
services. Services retain domain authorization such as record ownership and
tool permissions.

Implementation and gateway configuration live in `LPFchan/auth`. The MCP
inventory lives in `LPFchan/setup`. Read the Auth repository before changing
protocol or gateway behavior.

## Route policies

Every route has one explicit policy:

| Policy | Credential | Surface | Failure |
| --- | --- | --- | --- |
| `public` | none | deliberately public page or API | backend response |
| `oauth` | browser session | browser app and same-origin API | navigation redirects; API request `401` |
| `api` | machine token or browser session | script/browser HTTP API | `401`; Auth outage `503` |
| `mcp` | scoped machine token or resource-bound OAuth token | Streamable HTTP MCP | OAuth-aware `401`; Auth outage `503` |

`oauth` rejects machine credentials. Redirect only unsigned GET/HEAD browser
navigations; return `401` to API-style requests.

`public` applies to the entire matched path. Use narrow matchers for public
reads and protected writes. The gateway canonicalizes paths before matching
and rejects encoded slash or backslash.

## Identity and admission

- Browsers use the secure, HTTP-only `lp_auth` cookie. API clients use
  `Authorization: Bearer` or `X-API-Key`. MCP OAuth uses discovery,
  authorization code with PKCE S256, and resource-bound tokens.
- An explicit credential is authoritative. Invalid, revoked, incorrectly
  scoped, or ineligible credentials return `401` with no cookie or anonymous
  fallback.
- Auth enforces service visibility and `admin_only`. Authorization-data errors
  fail closed. The gateway accepts Auth's admission result.
- Use immutable `sub`, preferably `auth.lost.plus:<sub>`, for private records,
  idempotency, settings, caches, and queued work. Email and display name are
  presentation fields. Display names fall back to normalized email and contain
  at most 80 Unicode scalar values.
- Visibility keys and machine-token scopes are separate namespaces. The
  gateway sends `audience=<visibility-key>` and `service=<token-scope>`.

Successful identity:

```json
{ "sub": "123", "email": "...", "name": "...", "role": "administrator|user", "services": ["chat"] }
```

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

Trust these headers only on a private port behind the local gateway. Bind a
standalone service to loopback; containers may listen internally on `0.0.0.0`
when Docker publishes the host port on `127.0.0.1`.

Cookie-authenticated mutations and OAuth WebSocket handshakes require the exact
service origin. Interactive HTML denies framing with CSP `frame-ancestors
'none'` and `X-Frame-Options: DENY`.

Treat browser-cached identity as display state. Before private reads or writes,
refresh the session and verify the expected `sub`. Bind drafts, asynchronous
results, and queued writes to that subject; discard or quarantine them after an
account switch.

## MCP

- Protected routes publish `/.well-known/oauth-protected-resource/mcp` for the
  exact canonical `https://<host>/mcp` resource and required scope.
- `allow_anonymous: true` is for intentionally public operations. Missing
  credentials may pass; invalid explicit credentials still fail. Register the
  token scope even when it is hidden from the Apps page.
- The gateway owns MCP `GET`/`HEAD /healthz` and CORS preflight.
- Anonymous backends enforce streaming body limits, absolute read timeouts, and
  bounded in-flight work. Cancellation releases capacity after tool work ends.

## Adoption

1. Choose the hostname, longest `path_prefix`, methods, policy, visibility key,
   token scope, and loopback upstream. `oauth` needs visibility, `mcp` needs a
   scope, and `api` needs both.
2. Add and validate the route in `LPFchan/auth` at
   `deploy/<machine>/gateway.json`; register its keys and aliases.
3. Let the service parse trusted identity headers and enforce domain
   authorization. Point browser logout to `/_auth/logout`.
4. Route Cloudflare ingress through the machine gateway, normally
   `127.0.0.1:8740`, and keep the backend private.
5. Build from the reviewed Auth commit for the target architecture. Back up
   config and state before cutover; pair rollback images with compatible
   database snapshots.
6. Update the service documentation and Auth inventory. Reconcile MCP manifest,
   registry, gateway configuration, tests, and specification changes together.

Keep secrets out of configuration, documentation, commits, logs, and review
prompts.

## Failover

auth.lost.plus has a warm standby on Grimoire, kept current by Litestream
(5-min refresh from the OCI Object Storage replica). A watchdog on Grimoire
probes auth.lost.plus every minute; after 5 consecutive failures, it:

1. Checks other OCI-hosted services via Cloudflare DNS (all CNAMEs pointing
   at the OCI tunnel) to distinguish auth-specific issues from OCI outages.
   If any other OCI service is up, it treats this as an auth bug and does
   not fail over.
2. Fences the OCI instance via the OCI API (stops it).
3. Restores the standby DB from Litestream.
4. Starts `auth-standby.service` on Grimoire.
5. Adds auth.lost.plus ingress to Grimoire's Cloudflare tunnel config.
6. Repoints the auth.lost.plus DNS CNAME to Grimoire's tunnel.
7. Points Grimoire's gateway at the local standby.
8. Alerts the operator via Telegram (hermes).

If fencing fails (OCI API unreachable), the watchdog alerts but does not
promote — split-brain is worse than downtime.

Failback is manual: `sudo auth-failover-watchdog failback` on Grimoire.
This starts OCI, waits for auth health, reverts DNS/tunnel/gateway, and
stops the standby.

Implementation: `deploy/grimoire/auth-failover-watchdog.sh` in LPFchan/auth.
Rebuild runbook: `deploy/RUNBOOK.md` in the same repo.

## Verification

Run the affected repositories' full checks, then verify the deployed set:

- public, unsigned, allowed, restricted, invalid, and Auth-unavailable requests
  reach the expected response and backend boundary
- spoofed identity, proxy, cookie, and connection headers are stripped
- identity encoding preserves spaces, plus signs, Unicode, blank-name fallback,
  and the 80-character limit
- same-origin mutations succeed; cross-origin and wrong-subject work fails
- account switching cannot transfer private reads, writes, drafts, queues,
  favorites, or idempotency state
- MCP discovery, challenge, registration, PKCE, refresh, revocation, health,
  preflight, scope mismatch, optional anonymous access, and initialization work
- global and per-service machine-token modes enforce their registered scopes
- `/_auth/logout` invalidates the server session and expires the cookie

Record the deployed Auth, gateway, and service commits. Smoke-test production
after the coordinated rollout is complete.
