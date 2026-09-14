---
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
  browser sessions, machine tokens, roles, service visibility, and admission.
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
- API and MCP clients use `Authorization: Bearer <token>` or
  `X-API-Key: <token>`.
- An explicit machine credential is authoritative. Invalid, revoked,
  inactive-mode, incorrectly scoped, or service-ineligible credentials return
  `401`; never fall back to a cookie or anonymous access.
- Passkey, Google, and GitHub identities resolve to one Auth account.
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
  or `bunjang`.

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
| `mcp` | Scoped machine token only | Streamable HTTP MCP server | MCP-shaped `401`; Auth outage `503` |

An `oauth` route rejects machine-credential headers even when a valid cookie is
also present. An unsigned OAuth request redirects only for GET/HEAD browser
navigation (`Sec-Fetch-Mode: navigate` or an HTML `Accept` value); API-style
requests receive `401`.

An `mcp` route may set `allow_anonymous: true` only for intentionally public
MCP operations. Missing credentials then reach the backend anonymously, while
an explicit invalid credential still fails. The backend decides which MCP
methods and tools are public.

Treat `public` as a security boundary for the entire matched path. Split public
reads from protected writes with narrower route matchers, or make the backend
reject every non-public operation by default. In particular, a public catchall
must not make loopback-only maintenance endpoints writable through the
gateway.

`oauth` and cookie-authenticated `api` mutations require the exact service
origin. Apply the same check to OAuth-policy WebSocket handshakes.
Bearer-authenticated API requests do not need browser CSRF checks. Auth's own
state-changing management endpoints require the exact `auth.lost.plus` origin.

The gateway owns MCP `GET`/`HEAD /healthz` and CORS preflight. Other methods on
`/healthz` return `405` without reaching the MCP dispatcher.

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

Browser-cached identity is display state, not authority. Before replaying or
submitting private account-bound work, refresh the session and verify the same
immutable subject. Bind the expected subject into the request and have the
backend compare it with the gateway identity before writing. Discard a private
read response if the active subject changed while it was in flight. Quarantine
legacy email-owned state unless an explicit, verified email-to-sub migration is
available; never assign it to whoever signs in next.

## Integration workflow

1. Choose hostname, longest `path_prefix`, optional methods, policy,
   visibility key, token scope, and loopback upstream. `oauth` needs
   visibility; `mcp` needs token scope; `api` needs both; `public` needs
   neither.
2. Add the route to the Auth repo's tracked `deploy/<machine>/gateway.json`.
   Reject duplicate matchers and validate the complete machine config.
3. Remove the application's Common Auth credential validation. Parse only
   trusted gateway identity headers and retain domain-specific authorization.
4. Point browser logout to `/_auth/logout`. The gateway removes the server
   session and shared cookie, then returns to the service root.
5. Keep the backend private and point Cloudflare ingress at the machine's
   gateway, normally `127.0.0.1:8740`.
6. Build the gateway from the exact reviewed Auth commit on the target
   architecture. Back up config and state before cutover.
7. Use dashboard-issued global or per-service tokens for scripts and MCP
   clients. Auth stores new secrets as a SHA-256 validation hash plus
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
11. MCP health, rejected POST-to-health, preflight, optional anonymous calls,
    initialize, invalid token, scope mismatch, and revocation behave correctly.
12. Global mode works across registered scopes; per-service mode works only for
    its scope; switching modes twice reactivates preserved tokens without
    rotation.
13. `/_auth/logout` invalidates the server session and expires the shared
    cookie.

Record the deployed commit for Auth, each changed backend, and every gateway
machine. Run production smoke tests only after all parts of the final reviewed
set are installed, so partial rollout does not masquerade as a code failure.
