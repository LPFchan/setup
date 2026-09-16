---
audience: fleet
name: common-auth
description: Integrate or operate a lost.plus web service, API, or MCP server behind the per-machine Common Auth gateway using an explicit public, oauth, api, or mcp policy.
---

# Common Auth for lost.plus

Common Auth is the shared identity and admission boundary for lost.plus
services. `auth.lost.plus` owns accounts, browser sessions, machine tokens,
MCP OAuth, roles, service visibility, and admission. A stateless gateway on
each backend machine validates protected requests and forwards trusted
identity to a private local backend.

Services keep their own domain authorization, such as record ownership and
tool capabilities. They do not implement a second Common Auth client or token
parser. Cloudflare ingress terminates at the gateway; cross-machine ingress
may use Tailscale Serve to reach the destination gateway, never the
unprotected backend.

The canonical implementation and machine gateway configs live in
`LPFchan/auth`. The fleet-wide MCP inventory lives in the `mcp` manifest of
`LPFchan/setup`.

Before adopting Common Auth for a live service, or changing, reviewing,
testing, deploying, or operating an existing integration, read and follow
[the live-service adoption guide](references/live-service-adoption.md).
