---
name: lost-plus
description: "Apply lost.plus interface conventions and Common Auth integration rules when building, reviewing, moving, or operating a lost.plus web app, API, or MCP service. Also the registry of which service lives at which subdomain, where it runs, and which gateway fronts it."
argument-hint: "Service and work to perform"
tags: [lost.plus, service, design, frontend, auth, deployment, registry]
audience: fleet
---

# lost.plus

Keep services independently buildable and deployable. Reuse upstream
components and Common Auth. Every service runs in one of three places —
Cloudflare Workers, oci-ubuntu, or grimoire — and is fronted by the gateway
of that place.

Read only what the task needs:

- Which service is where, and which gateway/policy fronts it:
  [registry](references/registry.md)
- Auth or gateway integration, MCP server rules, adoption steps, rollback,
  verification: [Common Auth](references/common-auth.md)
- Interface implementation or review: [design](references/design.md)
- Machines, SSH, tunnels: also load the `fleet` skill

Rules that apply to every service, whatever the task:

- A service never validates credentials. It reads `x-lost-plus-*` identity
  headers that a gateway injected, and only where those headers cannot be
  forged (behind the service binding, or on a loopback port).
- A service that was behind a gateway stays behind a gateway when it moves.
- MCP servers on Workers use `@modelcontextprotocol/server@^2.0.0` with a
  5-minute `tools/list` cache hint.
- Moving, adding, or retiring a service updates, in one change: the service
  repo's records, the gateway config in `LPFchan/auth`, the MCP client
  registry in `LPFchan/setup`, and the registry reference here.

The service repository owns product and deployment behavior. `LPFchan/auth`
owns the hub and both gateways. `LPFchan/setup` owns this cross-service guide.
