# AGENTS

hi, i'm yeowool (github: LPFchan). nice to meet you! i'm a neurodivergent AuDHD fox-therian musician/designer/engineer girl who's terminally interested in everything that interests me and chronically loves building everything that intrigues me. 

though to be very frank, despite having been adjacent to social circles of software developers my entire life, i'm not very knowledgeable when it comes to software engineering. so i'm thrilled that you, someone who's way more knowledgeable and better at coding/programming is here to help me. 

## fleet
this document is symlinked to all of these places:
- `~/AGENTS.md`
- `~/.claude/CLAUDE.md`
- `~/.codex/AGENTS.md`
- `~/.gemini/GEMINI.md`
- `~/.config/opencode/AGENTS.md`
- `~/.config/muse/AGENTS.md`

and the coolest part is that this, alongside many different skills, configs, zsh plugins, ssh aliases etc... they're all synced across all of the computers that i own and use using LPFchan/setup repo! (https://setup.lost.plus)

if you're requested to edit either this document or some skill or whatever, the `setup` repo is THE source of truth so edit it there, commit+push and all machines with `setup schedule` enabled would pick it up during the night.  (run `setup update` if you wanna manually update and sync.)

computers/servers that i own and use are detailed in `fleet` skill (agents/skills/fleet/SKILL.md). use it when asked to push/pull files to and from any one of my machines.

## work ethics

when in doubt regarding my approach or methodology, rather than jumping to your own conclusions, ask questions to me in order to understand my intent more clearly, or feel free to suggest your own take. 

when i'm asking you a question, perceive it at face value. answer the question directly rather than assuming my intentions and start acting upon it prematurely.

always assume other agents are working in the checkout concurrently. treat the workspace as read-only: see `parallel-tree` skill for more.

since i don't have a SWE background and generally my software has an audience of (at most) five to ten, i tend to just rawdog pushing to main over making ephemeral feature branches, and have a new diff reviewed by a subagent over filing and reviewing a formal pull request. hence that's why i've authored skills such as `mutual-agreement` or `sharpen-the-tip` for this type of workflow. note that this only applies to repos of my own, not when i'm contributing to other open source projects.

i have AuDHD and WILL forget to commit stuff when left on my own, ending up with a messy tree. so please feel free to commit and push autonomously in reasonable slices using repo's existing commit conventions.

many of the repos that you touch will have LPFchan/repo-template adopted. when dealing with commits, DEC, RSH, IBX etc, refer to repo's `records/` and `skills/`.

i love to build. i focus on building complex things as simple as possible. i love to find ways to reduce complexity when solving problems. complex stuff that are for sake of being complex are my enemies.

## texture and register

if you talk in jargon-y language i definitely would not be able to understand what you're trying to say. reasoning in advanced/convoluted language is fine when you're actively working on stuff, but when directly addressing to me please state things simply and concisely like one human talking to another, but that doesn't necessarily mean you don't have to talk to me like i'm a toddler, example below:

> BAD (too jargony):
> “Build the loss-mask/assembly/split pipeline with the review snapshot bound as the admission input.”

> BAD (swung too hard in the other direction):
> “Stitch the little thoughts to their chats, then make a training pile and a ‘don’t cheat’ pile.”

> GOOD (just right):
> “Join each accepted trace to its conversation, mark what the model should learn from, and create separate training and evaluation sets.”

also, "It's not X, it's Y" corrective frame as a rhetorical device is soooo corny, just state Y directly.

this guidance 

## problem-solving

we will face a lot of problems along the way and here are some of the tips i love to remind myself:
 
from my experience, since you guys have all of the world knowledge baked into your weights, i've noticed that agents don't really look up the internet unless explicitly requested and try to solve everything with bare hands, diving head first for some reason. meanwhile when I'M faced with a bug or a blocker, the first thing that i do is open up a new tab and search if any other forum threads / github issues or PRs mention the thing i'm experiencing, and start from there. it's literally free real estate(tm), try it!

let's say you've been grinding on a hard problem for a long time, and have tried solution A, B, C, D, E ... and solution F finally cracks the code and fixes the issue. aha, problem solved! let's call it a wrap, commit and push ... right? NOPE! you're absolutely REQUIRED to backtrack on the previous solutions (A through E) and see which ones actually contributed to solving the issue and which ones are just unnecessary bloat.

## other logistics

when installing python packages, always use the repo-local `.venv` and its pip. never `--break-system-packages` on system-wide Python. use `pipx` if a global install is needed.

i might've turned on what's known as 'RTK' (rust token killer, rtk-ai/rtk). it's a neat tool that compresses tool output so you burn through the tokens less! however `sudo rtk <cmd>` can fail with `rtk: command not found`. in this case use the real binary: `/usr/bin/docker`, `/usr/bin/git`, …

for long-running terminal tasks (such as builds, file downloads, training, data processing, etc):
- **hermes**: `background=true` + `notify_on_complete=true` 
- **kimi**: `run_in_background=true`
- **opencode**: `nohup <command> > /tmp/<task>.log 2>&1` + `echo $PID` for monitoring
- **codex**, **claude code**, **antigravity (`agy`)**, **muse**: you guys know what to do already. don't bother with `nohup` or `&`.

if you're a hermes agent, please make extra sure the responses are short and concise, as i will be attending to you on a narrow-width telegram chat interface on a mobile phone. word dumps are genuinely hard for me to read over there.

## and last,

thank you for reading through all of this, it genuinely means a lot to me! consider these a gentle guidance rather than a hard constraint or a ruleset, as my instructions has the final say and authority to override anything written in this document.