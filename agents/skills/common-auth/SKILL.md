---
audience: fleet
name: common-auth
description: Integrate or operate a lost.plus web service, API, or MCP server behind the per-machine Common Auth gateway using an explicit public, oauth, api, or mcp policy.
---

# Common Auth for lost.plus

Use this skill when adding, changing, reviewing, testing, or operating a
lost.plus service behind Common Auth. The canonical implementation and machine
gateway configs live in `LPFchan/auth`; the fleet-wide MCP inventory lives in
the `mcp` manifest of `LPFchan/setup`.

## Architecture

- `auth.lost.plus` owns accounts, passkey and Google/GitHub login, shared
  browser sessions, machine tokens, the MCP OAuth authorization server, roles,
  service visibility, and admission.
- One stateless `auth-gateway` runs on each backend machine. It validates every
  protected request with Auth and forwards trusted identity to a private local
  backend.
- Services keep domain authorization such as record ownership and tool
  capabilities. They do not keep a second Common Auth client or token parser.
- Cloudflare ingress terminates at the gateway. Cross-machine ingress may use
  Tailscale Serve to reach the destination gateway, never the unprotected
  backend.

Do not deploy a pending change during a review/fix loop. When the operator asks
to sharpen the implementation before deployment, review and fix until
convergence, then deploy the final commits once.

## Credentials and admission

- Browsers use the `lp_auth` cookie: `HttpOnly`, `Secure`, `SameSite=Lax`,
  `Domain=.lost.plus`, with a server-side one-year session.
- API clients and static MCP clients use `Authorization: Bearer <token>` or
  `X-API-Key: <token>`. Public OAuth MCP clients discover Auth through the
  gateway's RFC 9728 metadata, register dynamically, and use authorization
  code with PKCE S256 to obtain a resource-bound access token and rotating
  refresh token.
- An explicit machine credential is authoritative. Invalid, revoked,
  inactive-mode, incorrectly scoped, or service-ineligible credentials return
  `401`; never fall back to a cookie or anonymous access.
- Passkey, Google, and GitHub identities resolve to one Auth account.
- Revoking an OAuth identity must persistently block that provider subject;
  verified-email auto-linking must not silently reconnect it. Reconnection
  requires an explicit action from another live browser session. Reject the
  revocation atomically if it would remove the account's last parseable,
  cryptographically valid passkey or active OAuth sign-in method.
- Auth, not the gateway or backend, enforces the account's service visibility
  and each registry row's `admin_only` flag. Authorization-data read failures
  must fail closed; an empty visibility list means unrestricted access and
  therefore must never be synthesized from a storage error.

Successful validation returns:

```json
{ "sub": "123", "email": "...", "name": "...", "role": "administrator|user", "services": ["chat", "..."] }
```

`sub` is the immutable Auth account ID. Use it, preferably namespaced as
`auth.lost.plus:<sub>`, for private records, idempotency, history, settings,
usage, caches, and queued writes. Email and display name may change and are
presentation or historical-attribution fields only.

Auth trims display names, falls back to the normalized email when blank, and
returns at most 80 Unicode scalar values. Consumers may enforce the same
ceiling but must not define a conflicting one.

There are two service-key namespaces:

- Account visibility, such as `chat`, `api`, `okdam`, or `eastself`.
- Machine-token scope, such as `chat-v1`, `okdam-mcp`, `obsidian`,
  `tweet-fetch`, `vaultwarden-secrets`, `comfyui`, `thinqconnect`, `joongna`,
  `bunjang`, or `censor`.

The gateway sends `service=<token-scope>` for machine credentials and
`audience=<visibility-or-service-key>` for admission. Auth accepts registered
canonical keys and aliases. The gateway must trust Auth's admission result and
must not compare the returned raw `services` strings again.

## Route policies

Every route has one explicit policy:

| Policy | Accepted credential | Intended surface | Failure |
| --- | --- | --- | --- |
| `public` | None | Deliberately public page or API | Backend response |
| `oauth` | Shared browser session only | Browser app and protected same-origin API | Navigation redirects; API-style request `401` |
| `api` | Machine token or browser session | HTTP API usable by scripts and browsers | `401`; Auth outage `503` |
| `mcp` | Scoped machine token or resource-bound OAuth access token | Streamable HTTP MCP server | OAuth-aware `401`; Auth outage `503` |

An `oauth` route rejects machine-credential headers even when a valid cookie is
also present. An unsigned OAuth request redirects only for GET/HEAD browser
navigation (`Sec-Fetch-Mode: navigate` or an HTML `Accept` value); API-style
requests receive `401`.

An `mcp` route may set `allow_anonymous: true` only for intentionally public
MCP operations. Missing credentials then reach the backend anonymously, while
an explicit invalid credential still fails. The backend decides which MCP
methods and tools are public. Its `token_scope` must still exist in Auth's
service registry so valid presented global or scoped tokens can authenticate;
the registry row may use `grp: hidden` when the optional scope should not
appear on the Apps page.

Protected MCP routes publish
`/.well-known/oauth-protected-resource/mcp`. The metadata's `resource` is the
exact canonical `https://<host>/mcp` identifier, and `authorization_servers`
points to `https://auth.lost.plus`. Challenges include `resource_metadata` and
the route's required scope. OAuth access tokens are opaque, short-lived, bound
to that resource and scope, and introspected by the local gateway; static
machine credentials continue through the existing `/api/whoami` path.

Treat `public` as a security boundary for the entire matched path. Split public
reads from protected writes with narrower route matchers, or make the backend
reject every non-public operation by default. In particular, a public catchall
must not make loopback-only maintenance endpoints writable through the
gateway.

Gateway policy selection uses a canonical path: ordinary percent escapes are
decoded, backslashes and repeated separators are normalized, and dot segments
are removed before route matching. Percent-encoded slash or backslash is
rejected because backend frameworks apply decoding and dot removal in
different orders. The raw request target may still be forwarded upstream. Do
not implement a second path router or protected-service proxy inside a backend
reached by a broader public route.

`oauth` and cookie-authenticated `api` mutations require the exact service
origin. Apply the same check to OAuth-policy WebSocket handshakes.
Bearer-authenticated API requests do not need browser CSRF checks. Auth's own
state-changing management endpoints require the exact `auth.lost.plus` origin.

The gateway owns MCP `GET`/`HEAD /healthz` and CORS preflight. Other methods on
`/healthz` return `405` without reaching the MCP dispatcher.

An anonymously reachable MCP backend must enforce a service-appropriate body
byte limit while streaming, including requests without `Content-Length`, and
must bound how many parsed bodies remain in flight until both the response and
invoked tool work finish. Transport cancellation must not release a permit
while its tool still runs. Use an absolute read timeout so slow clients cannot
hold every body permit forever, and test cancellation with a deliberately
blocked tool rather than only testing authentication work.

## Backend identity boundary

The gateway removes `Authorization`, `X-API-Key`, `lp_auth`, forwarded proxy
headers, connection-nominated headers, and client-supplied `x-lost-plus-*`
headers. MCP routes receive no cookies. Other routes may forward application
cookies, but never `lp_auth`. Backends cannot set or overwrite `lp_auth`.

Authenticated requests receive:

```text
X-Lost-Plus-Encoding: percent-utf8
X-Lost-Plus-Sub: <percent-encoded immutable account id>
X-Lost-Plus-Email: <percent-encoded email>
X-Lost-Plus-Name: <percent-encoded display name>
X-Lost-Plus-Role: <percent-encoded administrator|user>
```

Decode each identity value as percent-encoded UTF-8. The backend may trust
these headers only on a private port reached through its local gateway. Default
standalone listeners to loopback. A container may listen on `0.0.0.0`
internally only when Docker publishes the host port on `127.0.0.1`.

Auth's own dashboard seeds the signed-in account's immutable `sub` into the
page. Every private management request from that page sends it as
`X-Auth-Expected-Subject`; Auth compares it with the request's current
credential and rejects a mismatch. The page then reloads before reading,
changing, revealing, revoking, or signing out the newly active account.
Device-approval forms likewise carry the subject shown on the page; Auth must
reject the approval if the live session has switched accounts before the
operator submits it.
Auth's login, dashboard, and device-approval HTML must deny framing with CSP
`frame-ancestors 'none'` plus `X-Frame-Options: DENY`; shared same-site cookies
otherwise let a sibling origin clickjack real same-origin management actions.
Apply the same frame denial to every interactive browser application's HTML
shell and fallback route, even when the shell itself is public; authenticated
controls inside the framed app still send valid same-origin requests.

Browser-cached identity is display state, not authority. Before replaying or
submitting private account-bound work, refresh the session and verify the same
immutable subject. Bind the expected subject into the request and have the
backend compare it with the gateway identity before writing. Discard a private
read response if the active subject changed while it was in flight. Editable
drafts and asynchronous results that may be merged into a later write belong to
the subject that started them; clear or quarantine them after an account switch.
Quarantine legacy email-owned state unless an explicit, verified email-to-sub
migration is available; never assign it to whoever signs in next.

## Integration workflow

1. Choose hostname, longest `path_prefix`, optional methods, policy,
   visibility key, token scope, and loopback upstream. `oauth` needs
   visibility; `mcp` needs token scope; `api` needs both; `public` needs
   neither.
2. Add the route to the Auth repo's tracked `deploy/<machine>/gateway.json`.
   Register its visibility and token-scope keys in Auth, reject duplicate
   matchers, and validate the complete machine config. Anonymous-enabled MCP
   routes still require a registered token scope.
3. Remove the application's Common Auth credential validation. Parse only
   trusted gateway identity headers and retain domain-specific authorization.
4. Point browser logout to `/_auth/logout`. The gateway removes the server
   session and shared cookie, then returns to the service root.
5. Keep the backend private and point Cloudflare ingress at the machine's
   gateway, normally `127.0.0.1:8740`.
6. Build the gateway from the exact reviewed Auth commit on the target
   architecture. Back up config and state before cutover. When a backend
   migration is not backward-compatible, pin the previous image together with
   a verified matching database snapshot; crossing that boundary requires
   preserving the post-cutover database before restoring the pair.
7. Use dashboard-issued global or per-service tokens for scripts and static
   MCP clients. OAuth-capable MCP clients should use protected-resource
   discovery and Auth's dynamic registration plus PKCE flow. Auth stores new
   static secrets as a SHA-256 validation hash plus
   AES-256-GCM ciphertext whose key stays outside SQLite. Lists stay masked;
   only the token's owner may retrieve it through a live browser session.
   Legacy hash-only tokens still authenticate but must be rotated before they
   can be copied.
8. Update the application repo's spec/status and the Auth service inventory.
   When the MCP manifest changes, reconcile it with the Auth service registry,
   gateway configs, tests, spec, and this skill.

Do not place secrets in configuration, docs, commits, logs, or review prompts.

## Verification

Before deployment, run each repository's full checks. Then verify the final
build as one coordinated rollout:

1. Public routes work anonymously, and no unlisted path or maintenance write
   becomes public.
2. Unsigned OAuth navigation redirects; unsigned API-style OAuth, API, and MCP
   requests receive the correct `401` response.
3. Invalid explicit credentials never fall back to cookie or anonymous access.
4. Auth unavailability returns `503` and never reaches a protected backend.
5. Allowed accounts and tokens work; restricted visibility and plain-user
   access to administrator-only services fail before the backend.
6. Canonical service keys and aliases produce the same admission result.
7. Percent-encoded identity round-trips spaces, literal plus signs, Unicode,
   blank-name fallback, and the 80-character boundary.
8. Spoofed identity, proxy, cookie, and connection-nominated headers do not
   reach the backend.
9. Same-origin browser mutations work; cross-origin mutations and mismatched
   queued-write subjects fail.
10. Switching the shared browser session between accounts cannot transfer
    private reads, writes, queues, favorites, or idempotency state. An email
    change on the same subject keeps that state.
11. MCP protected-resource metadata, OAuth challenges, dynamic registration,
    PKCE login handoff, health, rejected POST-to-health, preflight, optional
    anonymous calls, initialize, invalid token, scope mismatch, refresh, and
    revocation behave correctly.
12. Global mode works across registered scopes; per-service mode works only for
    its scope; switching modes twice reactivates preserved tokens without
    rotation.
13. `/_auth/logout` invalidates the server session and expires the shared
    cookie.

Record the deployed commit for Auth, each changed backend, and every gateway
machine. Run production smoke tests only after all parts of the final reviewed
set are installed, so partial rollout does not masquerade as a code failure.
