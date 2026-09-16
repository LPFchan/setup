# lost.plus design

Use this reference when creating or reviewing a lost.plus web interface. It
captures stable family traits, not a component specification. The screenshots
are evidence and precedents, not pixel-perfect templates.

## What is fixed and what is not

These are invariants:

- quiet neutral surfaces, hairline separation, and one restrained accent
- information density chosen for the job, with strong hierarchy and little
  decoration
- semantic HTML, keyboard operation, visible focus, readable contrast, and
  reduced-motion support
- the service's product identity remains visible; family resemblance must not
  make every service look identical

These are defaults, not laws:

- system sans for prose and mono only for values people compare or copy
- 8px control radius, 10–12px large-card radius, and fully rounded pills
- 14–15px body copy, 20px page titles, and an 8px-based spacing rhythm
- dark near-black pages and warm off-white light mode selected through
  `prefers-color-scheme`

Break a default when the service's interaction requires it. A music timeline,
calendar, benchmark chart, and auth console should not share the same layout.
Explain exceptions in the service repository when they are not self-evident.

## Reuse before invention

Do not maintain a lost.plus UI package yet. Keep dependencies local to each
service, copy only the component code the service uses, and preserve the
existing framework unless a migration is part of the request.

For React:

- Use [shadcn/ui](https://ui.shadcn.com/) as the default source for accessible
  primitives and ordinary controls. Add components through its registry so
  their source lives in the service and remains editable.
- Use [beUI](https://beui.dev/) selectively when continuity or interaction
  motion is central to the experience.
- Use [Beautiful UI](https://www.beautifului.dev/) selectively for AI-native
  chat, tool-call, task, or approval surfaces.
- Use [Torph](https://torph.lochie.me/) for text morphing when changing text
  should preserve visual continuity.

For Svelte, use the equivalent shadcn-svelte/Bits UI primitive and Torph's
Svelte integration where useful. For static or server-rendered pages, prefer
native HTML and CSS. Never add React only to gain access to a component catalog.

[interfaces.dev](https://interfaces.dev/) is design-engineering guidance, not
a runtime dependency. Use it to study an interaction, then implement the
smallest version the product needs.

Before hand-writing a component, search the service and the sources above.
Reuse behavior and accessibility; restyle it with local tokens. Do not copy a
demo's visual effects, dependency stack, or abstraction layers by default.

## Family language

### Surfaces and colour

Backgrounds are neutral near-black without a strong blue or green cast. Light
backgrounds are warm off-white. Use one page background, at most two raised
tones, 1px hairlines, and a flat hover wash.

Each service chooses one accent for its primary action, content links, focus,
and selected state. Accent is not general decoration. Status colours keep
their meaning: green for healthy/success, amber for warning, and red for
danger. Per-item colours appear as small dots or marks, not large tinted cards.

No gradients or glows. Cards and rows do not need drop shadows; reserve a
subtle shadow for something that physically floats, such as a menu or sheet.

`../assets/tokens.css` is an accessible starting point, not a dependency. Copy
it into a new service, rename tokens to fit the local code, and test any changed
foreground/background pair. Existing services keep their established accent.

### Type and density

Use a plain system sans; add Pretendard when Korean-heavy text benefits from
it. Use monospace for hashes, times, bar numbers, song numbers, token counts,
prices, and other values people compare. Do not use it for all prose or every
button.

Use three readable text levels: primary, muted, and secondary metadata. Do not
make required information low-contrast. Uppercase tracked labels are reserved
for occasional section labels such as `APPS` or `MCP SERVERS`.

Prefer compact, scan-friendly rows for repeated records. Use a card only when
an item contains several related controls or needs a meaningful boundary.

### Shape and layout

- Controls normally use an 8px radius; large cards and sheets use 10–12px.
- Buttons are at least 32px high on dense desktop tools and 44px on touch-first
  screens. Icon-only actions need an accessible name and adequate hit target.
- Centre ordinary pages in a 736–1020px column with 20px desktop and 14px
  mobile padding. Full-bleed workspaces are correct for timelines, calendars,
  charts, and other spatial tools.
- A 52px top bar suits one or two sections. Use a sidebar only when persistent
  navigation across several sections is useful.
- Empty and error states use a short heading, one useful sentence, and at most
  one primary action. Illustration is optional, never filler.

### Motion

Motion should explain continuity or state change. Keep ordinary colour and
border transitions around 120–150ms. Do not add entrance animation, hover
movement, or ambient motion merely to make a page feel polished. Torph or beUI
is justified when the transition itself helps a person follow changing state.

Honor `prefers-reduced-motion`; do not rely on animation as the only state cue.

### Accessibility

- Meet WCAG AA contrast for normal text and interactive boundaries.
- Keep a visible 2px focus indicator with separation from the control edge.
- Support keyboard operation and logical reading/focus order.
- Label icon-only controls and announce new live activity briefly without
  replaying a backlog.
- Test narrow screens, zoom, long English/Korean/Japanese strings, loading,
  empty, error, and destructive states.
- Do not use colour alone to encode a status, series, or selection.

## Screenshot index

Open only the examples relevant to the surface being built:

| File | Service / pattern | What to study |
| --- | --- | --- |
| [ozlk](screenshots/SCR-20260916-ozlk.png) | heatmap overview | full-width calendar, compact filters, colour as data |
| [ozoh](screenshots/SCR-20260916-ozoh.png) | heatmap detail | editorial headline beside dense metrics and summaries |
| [ozrb](screenshots/SCR-20260916-ozrb.png) | okdam | multilingual search results, warm accent, row hierarchy |
| [ozsn](screenshots/SCR-20260916-ozsn.png) | coverse | spatial music workspace, restrained chrome, mono measures |
| [oztq](screenshots/SCR-20260916-oztq.png) | censor | single-purpose empty state and one obvious primary action |
| [pacw](screenshots/SCR-20260916-pacw.png) | artmu-bench | dense comparison chart, segmented filters, tabular results |
| [pafr](screenshots/SCR-20260916-pafr.png) | auth | sidebar console, compact rows, quiet administrative actions |

The examples intentionally vary. Copy the relevant structural lesson, not the
whole page. A search app should not inherit a benchmark's density; a creative
tool should not be forced into the auth console's sidebar.

## Review test

Reject or revise work when it has any of these without a product reason:

- tinted navy/teal backgrounds, decorative gradients, glows, or shadowed card
  grids
- accent colour on headings, borders, icons, and buttons all at once
- monospace everywhere, 800-weight headings, or tracked uppercase eyebrow text
  above every section
- decorative icons in coloured squares standing in for information hierarchy
- captions that only name the visible panel, repeated container nesting, or
  abstractions supporting one use site
- custom controls that lose keyboard, focus, labelling, or contrast behavior
  already available from an upstream primitive

Review against the running service at desktop and narrow widths. A screenshot
alone cannot prove focus behavior, overflow, motion, or accessibility.
