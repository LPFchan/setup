---
name: icic
description: "icic (in case it crashes) wakes you up every few minutes to check on a task you left running in the background, so you never sit waiting forever for a finish signal that never comes — a silent crash, a hang, or a watcher that misses the exit. Trigger: /icic <minutes>."
argument-hint: "interval in minutes (e.g. 10), or 'stop'"
---

# icic — In Case It Crashes

You started something in the background and said you'd report back when it's
done. Usually your harness pokes you when it finishes. icic is for when that
poke never lands: the process hangs, crashes quietly, or your watcher misses the
end — and you wait forever.

icic is a heartbeat. Every few minutes you wake up and go look at the work
yourself, instead of trusting that you'll be told.

## How to call it

- `/icic 10` — check the running background work every 10 minutes.
- `/icic` — default to every 10 minutes.
- `/icic stop` — turn the heartbeat off.

## Setting it up

1. **Know what you're watching.** Grab the handle for the running work — a task
   id, a log file, whatever lets you check on it later. Nothing running yet? Say
   so and set up icic once there is; don't arm an empty watch.
2. **Schedule the wake-up.** Use whatever your harness gives you to run yourself
   again on a repeat every N minutes, and bake the handle into it so the wake-up
   knows what to look at.
3. **Tell the user** what you're watching, how often, and that `/icic stop` ends
   it. Keep whatever id you get back so you can turn it off.

## What each wake-up does

Don't wait — look now.

- **Done** → finish the job you meant to do, then turn the heartbeat off. You're
  done.
- **Still going, still moving** → say one line about where it's at. Nothing else.
- **Stuck or dead** — no movement since last time, or an error/crash in the log —
  this is the whole point of icic. Tell the user what you found, fix it if you
  can, and turn the heartbeat off.

To tell "stuck" from "still going," compare against the one line you left last
time. Same spot twice in a row means stuck.

## Turning it off

Turn the heartbeat off the moment the work resolves — finished, crashed, or the
user said stop. If the normal finish signal shows up before a heartbeat, handle
it and turn icic off too, so it doesn't keep waking you.

## When not to reach for it

- If you can just wait on the task directly and it'll return soon, do that.
- If a live watcher already streams the event you care about, use that. icic is
  the backup for when that event, or the news of it, never arrives.
