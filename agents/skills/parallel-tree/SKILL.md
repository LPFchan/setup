---
name: parallel-tree
description: "Mint a worktree in a temporary location, do the requested work there, merge onto main, purge the worktree. Use when other agents are working concurrently in the same checkout, or when the operator says parallel-tree, work in your own tree, or don't touch this checkout."
argument-hint: "the change to make (optional — defaults to the work already requested)"
---

# Parallel Tree

Other agents are working in this checkout concurrently. Treat it as read-only:
mint your own worktree in a temporary location, do the work there, merge onto
main, purge the worktree when you're done with the work.

1. Resolve the real default branch and the repo root. Not a git repo, or no
   worktree support? Stop — don't fall back to the shared checkout.
2. `git worktree add -b pt/<slug> "$(mktemp -d)/…" <base>`, branching from the
   base tip. Keep it out of the repo, or it shows up in everyone's `git status`.
   Tracked files only — recreate `.venv` and friends in the worktree.
   Handing the tree to another agent instead of working in it yourself? Open
   its prompt with `<worktree-parent>/absolute/path/to/repo</worktree-parent>`
   — absolute, no trailing slash. Step 5 deletes the tree, and that line is
   then the only surviving record of which repo the work belonged to.
3. Do everything there. Never write to the shared checkout or its index.
4. Rebase onto the base tip. If main moved while you worked, resolve the
   conflict the correct way — in your tree, where it costs nobody else. Then
   land it with `git merge --ff-only` in the shared checkout, and push.
5. make sure to `git worktree remove`, `git branch -d`, `git worktree prune`. Confirm with `git worktree list`.

Your tree starts from committed history, so another agent's in-progress edits
aren't in it. If the work genuinely depends on them, say so and wait.

Coordinating slices across several agents instead? That's
[fan-out](../fan-out/SKILL.md) — this is what one worker does.
