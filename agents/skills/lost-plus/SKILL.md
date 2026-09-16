---
name: lost-plus
description: "Apply lost.plus interface conventions and Common Auth integration rules when building or reviewing a lost.plus web app, API, or MCP service."
argument-hint: "Service and work to perform"
tags: [lost.plus, service, design, frontend, auth, deployment]
audience: fleet
---

# lost.plus

Keep services independently buildable and deployable. Reuse upstream
components and Common Auth.

Read only what the task needs:

- Interface implementation or review: [design](references/design.md)
- Auth or gateway integration, testing, deployment, or operation:
  [Common Auth](references/common-auth.md)
- Host topology or remote work: also load the `fleet` skill

The service repository owns product and deployment behavior. `LPFchan/auth`
owns Auth and gateway behavior. `LPFchan/setup` owns this cross-service guide.
