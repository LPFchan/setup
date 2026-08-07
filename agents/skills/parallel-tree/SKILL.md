---
name: parallel-tree
description: "Do the requested work in a throwaway git worktree instead of the shared checkout, then fast-forward it onto the main branch and purge the worktree. Use when other agents are working concurrently in the same repo, or when the operator says parallel-tree, don't touch this checkout, work in your own tree, or someone else is editing here."
argument-hint: "the change to make (optional — defaults to the work already requested)"
---

# Parallel Tree

You are not alone in this checkout. Other agents are editing files, staging
things, and committing in the same working tree you're standing in. Anything
you do here — a stray `git add -A`, a branch switch, a stash, a half-finished
edit — lands in the middle of their work.

So don't work here. Mint your own worktree somewhere disposable, do the work
there, fast-forward it onto the main branch, and delete the worktree.

## The contract

The shared checkout is **read-only** to you, with exactly one exception: the
final fast-forward of the main branch. Everything else happens in your tree.

Creating a branch is normally off-limits without the operator asking. Invoking
this skill *is* the operator asking — a worktree can't check out a branch that's
already checked out elsewhere, so the temp branch is structural. It gets deleted
in step 5, so nothing is left behind.

## 1. Set up

Confirm you're in a git repo with worktree support, and find the real default
branch — don't assume `main`:

```sh
SHARED=$(git rev-parse --show-toplevel)
BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD | sed 's|^origin/||')
BASE=${BASE:-main}
```

Not a git repo, or worktrees unavailable? Stop and say so. Do not fall back to
working in the shared checkout — that's the one thing this skill exists to
prevent.

## 2. Mint the worktree

Branch from the **tip of the base branch**, not from the shared working tree:

```sh
SLUG=<short-kebab-description-of-the-change>
BRANCH="pt/$SLUG"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$(basename "$SHARED")-$SLUG-XXXXXX")
git -C "$SHARED" worktree add -b "$BRANCH" "$WORK" "$BASE"
```

Put it under the temp dir, never inside `$SHARED` — a worktree nested in the
repo shows up in everyone else's `git status` and file searches.

Your tree starts at committed history. Another agent's uncommitted edits are
not there, and that's correct: you build on what's landed, not on their work in
progress. If the requested change genuinely depends on something they haven't
committed, say so and wait rather than duplicating it.

Tracked files come across; ignored ones don't. If the work needs `.venv`,
`node_modules`, `.env`, or similar, recreate or symlink them in `$WORK` — per
the global rules, the venv is repo-local, so build a fresh one in the worktree
rather than pointing at the shared repo's.

## 3. Do the work

Run everything — edits, builds, tests, `git` commands — with `$WORK` as the
working directory. Commit there. Never `cd` back to `$SHARED` to run something
that writes, and never touch its index.

## 4. Land it

Rebase onto wherever the base branch is *now* — it may have moved while you
worked — then fast-forward the shared checkout:

```sh
git -C "$WORK" rebase "$BASE"
git -C "$SHARED" merge --ff-only "$BRANCH"
git -C "$SHARED" push        # if there's a remote
```

`--ff-only` is deliberate. It never writes a merge commit, and git refuses it
outright if the update would clobber uncommitted changes in the shared tree.

**If the fast-forward is refused**, another agent has live edits to files you
also changed. Stop. Do not force, do not stash their work, do not `checkout --`
anything. Report which files collide and leave your branch intact — the work is
safe on the branch and can land once they're done.

If the rebase conflicts, resolve it in `$WORK`. That's your tree; conflicts
there cost nobody else anything.

## 5. Purge

```sh
git -C "$SHARED" worktree remove "$WORK"
git -C "$SHARED" branch -d "$BRANCH"
git -C "$SHARED" worktree prune
```

Both commands are the safe variants on purpose. `worktree remove` refuses a
dirty tree and `branch -d` refuses an unmerged branch — either refusal means
work you were about to destroy. Investigate it; don't reach for `--force` or
`-D` to make the message go away.

Verify with `git -C "$SHARED" worktree list` that only the shared checkout
remains, then tell the operator what landed and that the tree is gone.

## When not to use it

- Nobody else is in the repo — just work normally.
- You're the coordinator handing slices to several subagents. That's
  [fan-out](../fan-out/SKILL.md); this skill is what one worker does.
- The task is read-only. Reading the shared checkout is fine; a worktree for it
  is pure overhead.
