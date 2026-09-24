---
audience: public
name: sketch
description: "Draw a visual explanation (diagram, comparison, flow, layout, table) as HTML+CSS, render it to a JPG with headless Chrome, and embed it inline in your reply. Use when the operator asks you to draw, sketch, diagram, visualize, or 'show me', or when a picture would explain something faster than prose."
---

# sketch

Think in HTML+CSS, render to JPG, send it inline. No hosting, no page to open.

## Steps

1. Write one self-contained HTML file to `~/.cache/sketch/<short-name>.html`.
   Inline all CSS. No external scripts. Web fonts are optional; the system
   sans-serif is fine.
2. Render it:
   ```bash
   node ~/.agents/skills/sketch/render.mjs ~/.cache/sketch/<short-name>.html
   ```
   It prints the absolute path of the JPG (same name, `.jpg`). Flags:
   `--width 1200` (viewport width in CSS px), `--scale 2` (pixel density).
3. Look at the JPG yourself before sending it. Fix clipping, overlaps, or
   unreadable text, then re-render.
4. Embed it in your reply with its absolute path: `![what it shows](/home/.../x.jpg)`.
   Keep the prose around it short. The picture carries the explanation.

## Layout rules

- The image is cropped to `<body>` plus its margins. Shrink-wrap the body
  (`body { width: max-content; margin: 0; padding: 32px; }`) or give it a fixed
  width, or the image will be as wide as the viewport.
- Set a `background` on `html` or `body`; a transparent page renders white.
- Aim for roughly 900–1400 CSS px wide. It will be read in a chat column.
- Plain language labels. One idea per box. Colour means something (e.g. green
  = pro, red = con) and stays consistent within the image.
- For arrows, use inline SVG positioned over a CSS grid/flex layout, or simple
  `→` glyphs between boxes. Don't hand-place everything with absolute pixels
  unless the drawing needs it.

## If rendering fails

- `no Chrome/Chromium found`: set `SKETCH_CHROME` to the browser binary.
- Needs Node 22+ (it uses the built-in WebSocket).
