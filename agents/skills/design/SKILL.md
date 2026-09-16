---
name: design
description: "lost.plus visual language. Load before writing or changing any web UI, page, stylesheet, or component for a lost.plus service, when reviewing a frontend diff, or when the operator says a UI looks generic, sloppy, or AI-generated. Records what heatmap, okdam, coverse, artmu, auth, and agent-with-agent actually look like so new work matches."
argument-hint: "Service or component you are styling"
tags: [design, frontend, css, ui, lost.plus]
audience: fleet
---

# lost.plus design language

This is the visual language shared by the lost.plus services as deployed:
heatmap, okdam, coverse, artmu-bench, auth, and agent-with-agent. It was
written from their live stylesheets and screenshots, so it records what is
there, not what someone wished for. Follow it when building or reworking a
service so the fleet reads as one family.

The short version: neutral surfaces, hairline borders, one accent used
sparingly, a plain sans for text and mono only for identifiers and numbers,
no gradients, no glows, no drop shadows on cards.

`tokens.css` next to this file is a ready starting stylesheet. Copy it and
change only the accent.

## Surfaces

Backgrounds are near-black neutrals with no blue or green cast. Every service
sits in the same narrow band:

| Service | Page | Raised | Line |
|---|---|---|---|
| artmu | `#111` | `#1b1b1b` / `#222` | `#2d2d2b` |
| heatmap | `#121416` | `#1a1d21` | `#343a40` |
| coverse | `#191919` | `#2b2b2b` | `#3d3d3d` |
| auth | `#1a1b1f` | `#202227` | `#32353c` |
| agent-with-agent | `#151619` | `#1b1c20` / `#222327` | `#34373d` |

Light mode is chosen by `prefers-color-scheme`, never a toggle. Light
backgrounds are warm off-white (`#f4f3ef` to `#f7f7f5`), surfaces white, lines
around `#d7dbe0`.

- One page background, at most two raised tones.
- Separate things with 1px hairlines at about 8% of the text colour. Solid
  `--line` is for control borders only.
- No box shadows on cards or rows. Shadows only on floating menus and sheets.
- No gradients, no radial glows.
- Hover is a flat 5% wash.

## Type

Body is a plain sans at 14 to 15px. Use the system stack; add Pretendard only
for heavy Korean text (heatmap does).

Monospace is for values a person copies or compares: UUIDs, hashes, times,
bar numbers, song numbers, token counts, prices. Never for body copy,
headings, or buttons.

| Role | Size | Weight |
|---|---|---|
| Page title | 20px | 600 |
| Row or item title | 13.5 to 15px | 500 to 600 |
| Body | 14 to 15px | 400 |
| Meta line | 12 to 13px, muted | 400 |
| Section label | 10 to 11px, uppercase, `.08em`, muted | 600 |
| Mono values | 11 to 13px | 400 |

Section labels ("APPS", "MCP SERVERS", "3 ROOMS") are the only uppercase,
letter-spaced text. One per section, never above every heading.

Text has three tones: primary, muted, faint. Faint is for timestamps, short
ids, and helper notes.

## Colour

Each service has one accent: primary button, links in content, focus ring,
selected or playhead state. Not for headings, borders, or decoration.

| Service | Accent |
|---|---|
| auth, agent-with-agent | blue `#4a6cf7` (dark `#5b7cff`) |
| coverse | blue `#0014ce` (dark `#7f8cff`) |
| okdam | yellow `oklch(80% .16 95)` |
| artmu | orange `#e07848` |
| heatmap | none, selection is a darker grey |

Semantic colours are shared: green for online, open, success; amber for
closed or warning; red for danger. Danger is red text, not a filled red
button.

Per-item colour (participant, project, track, model family) comes from a
small fixed palette and shows as an 8px dot, not a coloured background.

## Shape

- Buttons, inputs, small cards: 8px radius.
- Larger cards and sheets: 10 to 12px.
- Chips, pills, badges: fully round.
- Code blocks and tables: 6 to 8px. Nothing is square.

## Components

**Top bar.** 52px, hairline bottom, wordmark left (20px icon plus 15px/600
name), actions right. auth's console uses a 232px sidebar instead; use the
sidebar when a service has several sections, the top bar for one or two.

**Buttons.** 32px tall, 13px/500. Primary is accent-filled with white text,
one per view. Default is a `--line` border. Quiet has no border and muted
text, for row actions. Danger is quiet in red.

**Chips and pills.** 22 to 28px, fully round, raised fill or hairline
border, 12px text. Status pill is dot plus word. Category chip is dot plus
name plus optional mono id.

**Lists.** Hairline-separated rows, 12 to 14px vertical padding, no outer
card. Title and one muted meta line on the left, quiet actions on the right.
This is the dominant layout across the fleet.

**Cards.** Only when a thing has several controls. Raised surface, 10 to
12px radius, 16px padding. Not for plain lists.

**Inputs.** Field slightly lighter than the page, `--line` border, 8px
radius, 2px accent focus ring.

**Empty and error states.** Centred: short bold line, one muted sentence, one
button. No illustrations.

## Layout

- Centred column 736 to 1020px. Full-bleed only for tools that need width
  (coverse timeline, heatmap calendar).
- Page padding 20px, 14px on phones. Breakpoint 640px.
- Spacing on an 8px base: 8, 12, 14, 16, 20, 24, 28.

## Motion and accessibility

- Transitions 120 to 150ms on colour and border only. No hover movement, no
  entrance animation. One flash to highlight a jumped-to item is fine.
- `prefers-reduced-motion` turns all of it off.
- Focus always visible: 2px accent outline, 2px offset.
- Live regions announce new activity in one sentence; never read a backlog.

## Smell test

If a page has any of these, it will look generated next to the rest of the
fleet:

- tinted navy or teal backgrounds, diagonal gradients, glows
- the accent used for text, borders, and buttons all at once
- monospace everywhere
- an uppercase tracked label above every heading
- a grid of shadowed cards
- a decorative glyph in a coloured square as the logo
- 800-weight text
- captions that explain what the panel is ("read-only monitor")

`~/agent-with-agent/web/styles.css` on oci-ubuntu is a complete current
example of the language applied to a dashboard and a live transcript.
