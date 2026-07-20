---
name: fan-out
description: Delegate implementation across parallel subagents in isolated worktrees. Use when the operator asks to fan out, parallelize, split up, or distribute implementation work. Apply mutual-agreement to every slice. The coordinator must not implement.
---

# Fan Out

Use [mutual-agreement](../mutual-agreement/SKILL.md) for every slice.

1. Inspect the work and split it by actual dependencies, cohesion, and file ownership. Do not mechanically mirror the operator's bullets.
2. Group independent slices into parallel waves. Keep coupled changes together and give each shared boundary one owner.
3. Create a separate branch and worktree for every slice. Never let parallel agents share a writable checkout.
4. Give each subagent a complete mutual-agreement plan, its worktree path, owned scope, constraints, and verification criteria. Tell it not to commit or push.
5. Launch every unblocked slice in parallel.
6. Review and test each result. Commit accepted work; send rejected work back to its subagent. Do not edit it yourself.
7. Integrate accepted commits in dependency order and run final checks. Delegate conflicts, regressions, and missing glue; do not fix them yourself.
8. Remove worktrees only after integration is complete.

If fewer than two slices can safely run at once, say so and delegate the coherent work as one slice. If isolated worktrees are unavailable, stop rather than sharing a checkout.
