---
audience: public
name: sketch
description: "Draw a visual explanation (diagram, comparison, flow, layout, table) as HTML+CSS, render it to a JPG with headless Chrome, and embed it inline in your reply. Use when the operator asks you to draw, sketch, diagram, visualize, or 'show me', or when a picture would explain something faster than prose."
---

# sketch

Think in HTML+CSS, render to JPG, send it inline. No hosting, no page to open.

## Steps

1. Write one HTML file to `~/.cache/sketch/<short-name>.html`. Start it from
   the house style (below). Put your own CSS inline. No external scripts.
2. Render it:
   ```bash
   node ~/.agents/skills/sketch/render.mjs ~/.cache/sketch/<short-name>.html
   ```
   It prints the absolute path of the JPG (same name, `.jpg`). Flags:
   `--width 1200` (viewport width in CSS px), `--scale 2` (pixel density),
   `--light` (render the light theme; dark is the default).
3. Look at the JPG yourself before sending it. Fix clipping, overlaps, or
   unreadable text, then re-render.
4. Embed it in your reply with its absolute path: `![what it shows](/home/.../x.jpg)`.
   Keep the prose around it short. The picture carries the explanation.

## House style: lost.plus

Link the lost.plus token starter first. The path is relative to
`~/.cache/sketch/`:

```html
<link rel="stylesheet" href="../../.agents/skills/lost-plus/assets/tokens.css">
```

It loads Pretendard and defines light and dark colours, which switch with
`prefers-color-scheme`. Use its variables and never hardcode colours:
`--bg --surface --surface-2 --hair --line --text --text-muted --text-meta
--accent --accent-soft --ok --warn --danger --sans --mono`. Its `.pill`,
`.dot`, `.section-label` and `.row` classes are usable as-is.

- 1px `--hair` separators and borders. No shadows, gradients or glows.
- One `--accent` for the thing that matters most (the recommended option, the
  current step). Green/amber/red only for good/careful/bad, paired with a label.
- 8px radius for small boxes, 12px for cards, pills fully rounded.
- Monospace only for values people compare or copy. Uppercase tracked labels
  only for the occasional section heading.

If the lost-plus skill isn't on this machine, the link fails quietly; write
your own neutral near-black/off-white CSS in the same spirit.

## Layout rules

- The image is cropped to `<body>` plus its margins. Shrink-wrap the body
  (`body { width: max-content; margin: 0; padding: 32px; }`) or give it a fixed
  width, or the image will be as wide as the viewport.
- Aim for roughly 900–1400 CSS px wide. It will be read in a chat column.
- Plain language labels. One idea per box. Colour means something (e.g. green
  = pro, red = con) and stays consistent within the image.
- For arrows, use inline SVG positioned over a CSS grid/flex layout, or simple
  `→` glyphs between boxes. Don't hand-place everything with absolute pixels
  unless the drawing needs it.

## If rendering fails

- `no Chrome/Chromium found`: set `SKETCH_CHROME` to the browser binary.
- Needs Node 22+ (it uses the built-in WebSocket).
