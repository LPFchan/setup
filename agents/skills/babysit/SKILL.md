---
audience: public
name: babysit
description: "Loop on an open PR until automated reviewers go quiet: fetch bot review comments, triage, fix, push, repeat. Trigger: /babysit [PR number or URL], or 'babysit this PR'."
argument-hint: "PR number/URL (default: current branch's PR), or 'stop'"
---

# babysit

Shepherd a PR through automated review so the operator doesn't copy-paste bot feedback.

## Loop

1. **Wait for review.** Bots must have reviewed the current head commit. Check with
   `gh pr view <pr> --json headRefOid,reviews,statusCheckRollup` and
   `gh api repos/{owner}/{repo}/pulls/<pr>/comments`. Not reviewed yet → sleep, re-check.
2. **Triage** each unresolved bot comment on the latest round:
   - real bug / valid point → fix.
   - nitpick, false positive, out of scope → skip; reply on the thread with a one-line reason and resolve it.
3. **Fix** all accepted items in one commit (repo's commit conventions), push to the PR branch.
4. **Repeat** from 1.

## Done when

Bots reviewed the latest head, no new actionable comments, CI green. Then stop the
loop and report: rounds run, what was fixed, what was skipped and why.
Merge only if the operator asked to.

## Scheduling

Use the harness's recurring wake-up (e.g. `/loop`, cron, ScheduleWakeup) at ~5 min;
bake the PR number into the prompt. `/babysit stop` cancels it.

## Stop and ask the operator when

- A comment demands a product/design decision.
- Bots contradict each other or re-raise something already skipped.
- Same comment survives 2 fix attempts.
- CI fails for reasons unrelated to the diff.
