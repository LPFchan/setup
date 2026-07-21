---
name: mutual-agreement
version: 1.1
description: "Delegate work to a subagent with mutual review gates. Parent owns the plan and the commit. Subagent owns the implementation — or, if it disagrees, an adversarial review of the plan. Neither proceeds without the other's agreement."
argument-hint: "Goal statement, file paths, and constraints for the change to delegate"
---

# Mutual Agreement

A delegation pattern where a parent agent and a subagent each own one phase
and must agree before the other proceeds. Neither side does both planning and
execution. The gates are explicit.

## Handoff model

```
Parent ──[plan]───────────────▶ Subagent
                                    │
              agrees ──[implementation]──┐
           disagrees ──[adversarial review]──┐
                                    ▼        ▼
Parent ◀────────────────────── Subagent's response
   │
   ├─ agrees    → [review + commit/push] ──▶ repo
   └─ disagrees → [re-present revised plan] ──▶ back to top
```

The only exit is mutual agreement: the subagent agrees enough to implement,
*and* the parent agrees enough to commit. Any disagreement on either side
loops back through a revised plan.

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
> "Only implement if you agree with the plan. If you disagree with any part, do
> NOT implement — instead adversarially review the plan: attack it, surface its
> failure modes and unhandled cases, and make the strongest case against it. Do
> not commit or push."

### Phase 2: Subagent → Parent (implementation OR adversarial review)

The subagent reads the plan, evaluates it, and either:

- **Agrees** → implements the changes, writes them to disk. The subagent's
  response IS the implementation — not a proposal, not a description. The
  parent sees the diff when it reviews. Does NOT commit or push.
- **Disagrees** → performs an **adversarial review of the plan**: actively
  tries to break it. Surfaces failure modes, hidden assumptions, unhandled
  edge cases, and cheaper or safer alternatives — the strongest case *against*
  the plan, not a hedged note. Returns that critique. Does NOT implement.

When the subagent agrees, its response is the **implementation artifact** the
parent reviews: the parent must see which files changed, what the diff looks
like, and any deviations from the plan. When it disagrees, its response is the
**critique** the parent weighs before re-presenting the plan.

### Phase 3: Parent reviews the subagent's output

Parent reviews whatever the subagent returned — an implementation, or an
adversarial review:

- **Agrees** → reviews the implementation and commits/pushes (or applies to the
  live system, or whatever the final action is). This is the parent's
  responsibility, never the subagent's.
- **Disagrees** — because the parent finds the implementation wrong, *or*
  because the subagent's adversarial review landed → re-presents the plan:
  revise it in light of the critique (or defend it against a critique the
  parent rejects), and re-dispatch to Phase 1. The loop continues until both
  sides agree.

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
- **Subagent commits or pushes.** The subagent's job ends at writing files to
  disk. The commit is the parent's explicit agreement. If the parent doesn't
  commit, the implementation is rejected. Never include "commit+push" in the
  subagent's dispatch prompt — include "do not commit or push" instead.
- **Parent rubber-stamps the implementation.** If the parent doesn't actually
  review the diff, the agreement gate is theater. Read the changes. Verify
  the verification criteria from the plan.
- **Subagent implements despite disagreeing.** If the plan is wrong, don't
  implement it — adversarially review it instead. Don't build something you
  think is incorrect just because the parent asked.
- **"Adversarial review" that's just a soft note.** Disagreement means
  attacking the plan in earnest — the strongest case against it, with concrete
  failure modes. A couple of hedged concerns isn't the gate doing its job.
