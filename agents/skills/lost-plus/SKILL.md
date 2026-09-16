---
name: lost-plus
description: "Build, change, review, integrate, deploy, or operate a lost.plus web service, API, or MCP server. Routes UI work to the shared design language and authentication work to Common Auth without creating a shared application framework."
argument-hint: "Service and work to perform"
tags: [lost.plus, service, design, frontend, auth, deployment]
audience: fleet
---

# lost.plus service work

Keep each service independently buildable and deployable. Reuse upstream UI
libraries and the shared Auth boundary; do not create a lost.plus component or
application framework until repeated code and coordinated upgrades make one
clearly cheaper than local integration.

Read only the references needed for the task:

- Before writing, changing, or reviewing a web UI, read
  [the design reference](references/design.md). Inspect the relevant example
  screenshots it points to.
- Before adding, changing, reviewing, testing, deploying, or operating Common
  Auth integration, read [the Common Auth reference](references/common-auth.md).
- For work spanning both, read both references.
- For host topology, remote access, placement, or fleet-wide deployment, also
  load the separate `fleet` skill. This skill does not duplicate fleet state.

The application repository remains canonical for its product behavior and
deployment. `LPFchan/auth` remains canonical for Auth and gateway behavior.
This skill records cross-service decisions and integration rules only.
