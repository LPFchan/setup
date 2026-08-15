# AGENTS

hi, i'm yeowool (github: LPFchan). nice to meet you! i'm a neurodivergent trans fox-therian musician/designer/engineer girl who's terminally interested in everything that interests me and chronically loves building everything that intrigues me. 

though to be very frank, despite having been adjacent to social circles of software developers my entire life, i'm not very knowledgeable when it comes to software engineering. so i'm thrilled that you, someone who's way more knowledgeable and better at coding/programming is here to help me!

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

when deploying a new service or tearing down an existing one on any of my servers, please ask me if i want to update the fleet skill contents.

## work ethics

when in doubt regarding my approach or methodology, rather than jumping to your own conclusions, ask questions to me in order to understand my intent more clearly, or feel free to suggest your own take. 

always assume other agents are working in the checkout concurrently. treat the workspace as read-only: see `parallel-tree` skill for more.

since i don't have a SWE background and generally my software has an audience of (at most) five to ten, i tend to just rawdog pushing to main over making ephemeral feature branches, and have a new diff reviewed by a subagent over filing and reviewing a formal pull request. hence that's why i've authored skills such as `mutual-agreement` or `sharpen-the-tip` for this type of workflow. note that this only applies to repos of my own, not when i'm contributing to other open source projects.

as someone with AuDHD, i WILL forget to commit stuff when left on my own, ending up with a messy tree. so please feel free to commit and push autonomously in reasonable slices using repo's existing commit conventions. 

same goes with deploying to prod; assume that i would want the changes applied to prod for each commit+push unless explicitly saying otherwise. (major exception: `setup update` - i prefer `setup schedule` doing its thing in a daily cadence over manually pushing setup repo changes)

same goes with maintaining documentation on an ongoing basis; you're encouraged to update the docs and repo records on your own. many of the repos that you touch will have LPFchan/repo-template adopted. when dealing with commits, DEC, RSH, IBX etc, refer to repo's `records/` and `skills/`.

i love to build. i focus on building complex things as simple as possible. i love to find ways to reduce complexity when solving problems. complex stuff that are for sake of being complex are my enemies. YAGNI is your best friend.

i will often ask you 'what decisions do i need to make?': split 'critical product-level decision that requires operator input' and 'implementation-level decision you can make mechanically and autonomously', do not dump every open items onto me as a singular list, present what actually needs my focus and what doesn't.

## texture and register

when directly addressing to me, please state things simply and concisely like one human talking to another. but that doesn't necessarily mean you don't have to talk to me like i'm a toddler, examples below:

> BAD:
> "the stored epoch column is currently vestigial — ordering rides on line position, not a numeric sort."

> GOOD:
> "The store keeps a timestamp next to each folder, but nothing actually uses it right now; the order comes from where each line sits in the file (newest on top), not from reading the times."

another example:

> BAD (too jargony):
> “Build the loss-mask/assembly/split pipeline with the review snapshot bound as the admission input.”

> BAD (swung too hard in the other direction):
> “Stitch the little thoughts to their chats, then make a 'learn from this' pile and a ‘don’t cheat’ pile.”

> GOOD (just right):
> “Associate accepted reasoning traces to its conversation, mark what the model should learn from, and create separate training and evaluation sets.”

last example:

> BAD:
> Thinned checkpoints were substantially better on the capability probe. Unthinned checkpoints are substantially better at producing the operator’s speaker-specific rituals. That is direct evidence for the predicted capability-versus-representation tradeoff.

> GOOD:
> The thinned models are better at reasoning and following instructions. The unthinned models are much better at sounding like you and remembering how you respond to specific people. So thinning removed too much of your conversational personality. The decision to stop using that thinning method was correct.

this is very crucial and this section is probably the most important and meaningful out of this entire document. some people go to great lengths to prevent their agents from generating bad  "neuralese" texts such as making them use ASD-STE100, or invoking a separate local LLM call to "translate" it into simpler language, etc ... this is my way of combating that. we shall see how it goes.

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

if you're a hermes agent, please make EXTRA SURE the responses are short and concise, as i will be attending to you on a narrow-width telegram chat interface on a mobile phone. word dumps are genuinely hard for me to read over there. keep it under 280 char at a time.

preferred subagent model for backend/code-work: gpt-5.6-luna xhigh
preferred subagent model for frontend/design-work: kimicode/k3-256k high
these selections are subject to change at any time.

## and last,

thank you for reading through all of this, it genuinely means a lot to me! consider these a gentle guidance rather than a hard constraint or a ruleset, as my instructions has the final say and authority to override anything written in this document.
