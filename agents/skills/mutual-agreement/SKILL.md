---
name: mutual-agreement
version: 1.0
description: "Delegate work to a subagent with mutual review gates. Parent owns the plan and the commit. Subagent owns the implementation. Neither proceeds without the other's agreement."
---

# Mutual Agreement

A delegation pattern where a parent agent and a subagent each own one phase
and must agree before the other proceeds. Neither side does both planning and
execution. The gates are explicit.

## Handoff model

```
Parent ──[plan]──▶ Subagent
Parent ◀──[implementation]── Subagent
Parent ──[review + commit/push]──▶ repo
```

### Phase 1: Parent → Subagent (plan only)

Parent formulates a **complete, self-contained plan** and hands it to a
subagent via `delegate_task`. The plan includes:

- **Goal** — what the change achieves, in one sentence
- **Background** — why the change is needed, with enough context for the
  subagent to evaluate the plan independently (file paths, current behavior,
  constraints, design history if relevant)
- **Proposed changes** — numbered steps describing what to add/remove/modify,
  with specific line numbers, function names, or code snippets where possible
- **Verification criteria** — how to confirm the implementation is correct
- **Constraints** — what the subagent must NOT do (e.g. do not commit, do not
  modify unrelated files, do not change the interface unless the plan says so)

The plan must NOT include implementation code. It describes what to do, not
the final diff. This is deliberate: the subagent's job is to translate the
plan into code, which is a separate reviewable artifact.

The subagent prompt must include:
> "Only implement if you agree with the plan. If you disagree with any part,
> explain why and propose alternatives. Do not commit or push."

### Phase 2: Subagent → Parent (implementation only)

The subagent reads the plan, evaluates it, and either:

- **Agrees** → implements the changes, writes them to disk, and returns a
  summary of what it did (files changed, lines added/removed, any decisions
  it made that weren't specified in the plan). Does NOT commit or push.
- **Disagrees** → returns an explanation of what's wrong with the plan and
  proposed alternatives. Does NOT implement.

The subagent's response is the **implementation artifact** the parent reviews.
The parent must see: which files changed, what the diff looks like, and any
deviations from the plan.

### Phase 3: Parent reviews implementation

Parent reviews the subagent's output:

- **Agrees** → commits and pushes (or applies to the live system, or whatever
  the final action is). This is the parent's responsibility, never the
  subagent's.
- **Disagrees** → reverts or patches the implementation, then either commits
  a corrected version or re-dispatches the subagent with an updated plan.

The parent's commit message should credit the subagent's implementation while
reflecting the parent's review (e.g. if the parent fixed something the
subagent got wrong, the commit message notes it).

## When to use this pattern

- Refactoring or restructuring existing code (the subagent needs to understand
  the full before proposing changes)
- Changes where the plan has meaningful alternatives the subagent might flag
- Any change to shared infrastructure, fleet config, or production systems
- When the user explicitly asks for mutual agreement

## When NOT to use this pattern

- Simple, well-scoped changes (just do it directly)
- Pure research or analysis (no implementation to gate)
- When the user says "you do it" (they've delegated full authority)

## Anti-patterns to avoid

- **Parent includes implementation code in the plan.** This defeats the
  purpose — the subagent becomes a copy-paste executor, not a reviewer.
  The plan should describe what, the subagent figures out how.
- **Subagent commits without parent review.** The commit is always the
  parent's call. Even if the implementation looks correct, the parent
  should verify the diff before pushing to shared state.
- **Parent rubber-stamps the implementation.** If the parent doesn't actually
  review the diff, the agreement gate is theater. Read the changes. Verify
  the verification criteria from the plan.
- **Subagent implements despite disagreeing.** If the plan is wrong, say so.
  Don't implement something you think is incorrect just because the parent
  asked.
