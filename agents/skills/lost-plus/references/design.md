# Design

Build a recognizable family of distinct products. Use the relevant screenshot
as a structural precedent, then follow the needs of the service.

## Sources

Keep dependencies and copied component code in the service repository.
Preserve its existing framework unless the task includes a migration.

- React: use [shadcn/ui](https://ui.shadcn.com/) for ordinary accessible
  controls, [beUI](https://beui.dev/) for interaction-led motion,
  [Beautiful UI](https://www.beautifului.dev/) for AI-native surfaces, and
  [Torph](https://torph.lochie.me/) for text continuity.
- Svelte: use shadcn-svelte or Bits UI, plus Torph where useful.
- Static and server-rendered pages: use semantic HTML and CSS.
- Use [interfaces.dev](https://interfaces.dev/) to study interaction patterns.

Search the service and these sources before writing a custom control. Copy the
smallest useful component, retain its accessible behavior, and style it locally.

## Visual language

- Neutral near-black dark surfaces and warm off-white light surfaces.
- One restrained service accent for primary actions, links, focus, and
  selection. Green means success, amber warning, and red danger.
- One page background, at most two raised tones, 1px separators, and flat hover
  states. Shadows belong to floating menus and sheets.
- System sans for prose. Add Pretendard for Korean-heavy text. Use monospace for
  values people compare or copy.
- Primary, muted, and metadata text must remain readable. Reserve uppercase
  tracked labels for occasional section headings.
- Prefer compact rows for repeated records. Use cards for grouped controls.
- Default to 8px control radii, 10–12px large-card radii, and rounded pills.
- Use a centred 736–1020px column for ordinary pages and full width for spatial
  tools such as timelines, calendars, and charts.
- Use a top bar for shallow navigation and a sidebar for several persistent
  sections.
- Motion explains continuity or state change. Keep ordinary transitions around
  120–150ms and honor `prefers-reduced-motion`.

Copy [the token starter](../assets/tokens.css) into a new service and adapt its
accent. Existing services keep their established accent.

## Accessibility

- Meet WCAG AA contrast and keep a visible 2px focus indicator.
- Support keyboard operation and logical focus order.
- Give icon-only controls accessible names and practical hit targets.
- Pair colour with another status or selection cue.
- Test narrow screens, zoom, long English/Korean/Japanese strings, loading,
  empty, error, and destructive states.

## Examples

Open only the examples relevant to the surface:

| File | Service | Study |
| --- | --- | --- |
| [ozlk](screenshots/SCR-20260916-ozlk.png) | heatmap overview | calendar, filters, colour as data |
| [ozoh](screenshots/SCR-20260916-ozoh.png) | heatmap detail | editorial hierarchy with dense metrics |
| [ozrb](screenshots/SCR-20260916-ozrb.png) | okdam | multilingual results and row hierarchy |
| [ozsn](screenshots/SCR-20260916-ozsn.png) | coverse | spatial workspace and restrained chrome |
| [oztq](screenshots/SCR-20260916-oztq.png) | censor | focused empty state and primary action |
| [pacw](screenshots/SCR-20260916-pacw.png) | artmu-bench | comparison chart, filters, tabular results |
| [pafr](screenshots/SCR-20260916-pafr.png) | auth | sidebar console and administrative rows |

## Review

Review the running service at desktop and narrow widths. Check focus, keyboard
use, overflow, motion, loading, empty, error, and destructive states.

Challenge decorative gradients, glows, shadowed card grids, pervasive
monospace or uppercase text, excess accent colour, repeated containers, and
custom controls with weaker accessibility than an available primitive. Keep
them only when they serve the product.
