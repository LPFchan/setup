# setup-bg — the motion background for setup.lost.plus

A 28s, 60fps, seamlessly looping clip of this system in use. It is not a mockup:
every terminal frame is a **real recorded zsh/tmux session** replayed in
xterm.js inside headless Chrome, with a camera driven over it.

    index.html  ->  /media/setup-bg-1080p.mp4   (and -720p, -poster.jpg)

## How it works

1. **`seed_sandbox.py`** builds `sandbox/` — a throwaway `$HOME` holding the
   fleet's ssh config, per-machine tmux configs generated from
   `files/tmux.sh`, stub harness binaries, and populated session stores for
   Claude Code, Codex, OpenCode, ForgeCode, Hermes and Grok. That is what lets
   the *real* `bin/setup`, `files/resume` and `files/ai-menu` from this repo
   produce real output with nothing mocked.

2. **`rec.py`** drives that sandbox through a pty and records every byte the
   terminal emits, with timestamps, into `casts/*.json`. Mouse interaction is
   recorded by injecting SGR mouse sequences straight into the client — the
   exact bytes a terminal sends when you click and drag.

3. **`stage.html` + `timeline.js`** replay the casts in xterm.js and move a
   camera over them. The DOM renderer is used deliberately: text re-rasterises
   at whatever scale the camera is at, so extreme close-ups stay crisp.

4. **`render.mjs`** steps the stage one frame at a time under headless Chrome
   and pipes the frames to ffmpeg.

## Regenerating

    npm install                       # puppeteer-core + @xterm/xterm
    python3 seed_sandbox.py           # build sandbox/
    python3 rec.py                    # record casts/
    node render.mjs master.mp4        # 1680 frames -> master
    ./encode.sh                       # 1080p, 720p, poster -> ../

Needs Google Chrome at the standard macOS path, plus `tmux`, `zsh`, `jq`,
`sqlite3`, `starship` and `~/.local/bin/fzf-multicolumn`.

Recording and rendering are separate on purpose: `casts/` is committed, so the
video can be re-rendered — different length, different framing — without
re-recording anything.

## Inspecting

    node dump.mjs <cast> [t,t,...]    # replay a cast, print the screen as text
    node barscan.mjs <cast> [t0 t1]   # report every frame the status bar changes
    node probe.mjs "1.0,5.0,9.0"      # render single frames of the timeline

`dump.mjs` and `barscan.mjs` are how the camera gets aimed: shots are specified
in terminal cells (column, row), not pixels, so they point at actual glyphs.

## Notes

* **Machine colour.** `zsh-basics` derives a hue per host from
  `cksum(hostname) % 360` at full saturation, and `tmux.sh` paints the whole
  status bar with it. The seeder runs that same computation, so the colours on
  screen are the fleet's real ones: yeowoolair `#A100FF`, grimoire `#44FF00`,
  bingus `#00E5FF`, yeowoolmac `#0090FF`, oci-ubuntu `#DDFF00`.

* **Drag priming.** tmux spends the first motion event after a button press
  establishing the drag; it never reaches `MouseDrag1Status`. `rec.py` sends a
  priming motion that stays inside the grabbed tab (so the binding it fires is
  a no-op self-swap) — without it the first reorder tick is dropped and the tab
  appears to jump two positions.

* **Boundary hysteresis.** `swap-window` exchanges tabs of different widths, so
  the boundary moves out from under a stationary cursor and the next motion
  swaps it straight back. The pointer path is therefore smooth, but the events
  sent to tmux land on tab centres: one swap per tab crossed, no oscillation.
