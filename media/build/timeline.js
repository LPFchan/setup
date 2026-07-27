/* setup.lost.plus background — 28s, 60fps, seamless loop.
 *
 * Everything on screen is a real recorded zsh/tmux session replayed in
 * xterm.js. The camera does all the work.
 *
 * Two rules govern it:
 *
 *   Aim in cells, not pixels. Shots are specified as (column, row) in a
 *   screen's own grid, so they point at actual glyphs. `node dump.mjs <cast>`
 *   prints those grids.
 *
 *   Move along one axis at a time. Every shot either tracks horizontally (row
 *   held), falls vertically (column held), or zooms on a fixed point. Nothing
 *   drifts diagonally; where a beat needs both, it is cut into two right-angle
 *   moves. Terminals are a grid — the camera moves along it.
 */

const DUR = 28.0;

// One xterm per cast, all at the same font, so scene space is a single uniform
// cell grid shared by every layer.
const FONT_PX = 18;
const SCREENS = {
  aimenu:  { cast: 'aimenu',  font: FONT_PX, at: [0, -40] },
  bartabs: { cast: 'bartabs', font: FONT_PX, at: [0, -80] },
  nested:  { cast: 'nested',  font: FONT_PX, at: [0, -120] },
  picker:  { cast: 'picker',  font: FONT_PX, at: [0, -160] },
  resume:  { cast: 'resume',  font: FONT_PX, at: [0, -200] },

  // The fleet, as a vertical cascade. 10-row pitch against 18-row tiles: they
  // overlap into a deck, and the pitch is under the frame height at the fall's
  // zoom, so a machine-colour band is always crossing frame.
  tile_grimoire: { cast: 'tile_grimoire', font: FONT_PX, at: [0, 0] },
  tile_mac:      { cast: 'tile_mac',      font: FONT_PX, at: [9, 10] },
  tile_bingus:   { cast: 'tile_bingus',   font: FONT_PX, at: [2, 20] },
  tile_oci:      { cast: 'tile_oci',      font: FONT_PX, at: [11, 30] },

  // yeowoolair, running setup itself — so its band reads ` yeowoolair    setup `
  // and the word the piece opens and closes on is the product name, printed by
  // the real status bar. Clears oci entirely (30+18) plus a gap, so nothing is
  // ever stacked above the band the camera lands in. Shots 1 and 14 both use
  // this screen at the same frozen instant, so the loop join needs no
  // cross-fade: the last frame and the first frame are the same render.
  air_setup: { cast: 'picker', font: FONT_PX, at: [4, 49] }
};

const AIR_BAR_ROW   = 49.5;   // scene row of the centre of yeowoolair's band
const SETUP_WORD_COL = 17;    // ` setup ` sits at cols 15-19: 1 pad + p12 host + 1 pad
const SETUP_ABS_COL  = 4 + SETUP_WORD_COL;   // same point in absolute scene cells
const PICKER_SETTLED = 9.2;   // cast time once the module table has rendered

const E = {
  lin:  t => t,
  inOutCubic: t => t < .5 ? 4*t*t*t : 1 - Math.pow(-2*t+2, 3)/2,
  // nearly constant through the middle — for tracking a subject that is itself
  // moving at a steady rate, so the camera neither outruns nor lags it
  inOutSine: t => -(Math.cos(Math.PI * t) - 1) / 2,
  outQuart: t => 1 - Math.pow(1 - t, 4),
  outSpring: t => t >= 1 ? 1 : 1 - Math.pow(2, -9*t) * Math.cos(t * 11.5)
};

const clamp01 = v => v < 0 ? 0 : v > 1 ? 1 : v;
const lerp = (a, b, t) => a + (b - a) * t;

const SHOTS = [
  // 1 · THE WORD. Opens on `setup` filling the frame inside yeowoolair's
  //     machine-colour band. ZOOM OUT, locked on it, until the bar and the
  //     picker beneath it read. Eased at both ends so the loop seam has zero
  //     camera velocity either side of it — the join is a held beat.
  { id: 'air_setup', t0: 0.00, t1: 2.20, cast: [PICKER_SETTLED, PICKER_SETTLED],
    ease: 'inOutCubic',
    from: { c: SETUP_WORD_COL, r: 0, s: 34 }, to: { c: SETUP_WORD_COL, r: 0, s: 5.0 } },

  // 2 · FALL down the tool column: claude, codex, claudex, claudex-cc,
  //     opencode, hermes, grok. Column held, camera drops.
  { id: 'aimenu', t0: 2.20, t1: 4.30, cast: [2.30, 4.40], ease: 'inOutCubic', cut: true,
    from: { c: 11, r: 0, s: 6.2 }, to: { c: 11, r: 8, s: 6.2 } },

  // 3 · TRACK RIGHT across the three tracks — tools, ssh hosts, recent
  //     folders. This is the ai-menu's whole idea in one move.
  { id: 'aimenu', t0: 4.30, t1: 6.05, cast: [4.40, 6.15], ease: 'inOutCubic', cut: true,
    from: { c: 8, r: 7, s: 5.6 }, to: { c: 34, r: 7, s: 5.6 } },

  // --- 4-6 · THE BAR. One continuous take, no cuts: the window row filling
  // --- up, then being reordered by hand. Both halves are the same subject.

  // 4 · TRACK RIGHT while the tabs open one at a time, each new harness
  //     appearing just ahead of the camera.
  { id: 'bartabs', t0: 6.05, t1: 8.30, cast: [0.30, 2.90], ease: 'inOutSine', cut: true,
    from: { c: 18, r: 0, s: 9.0 }, to: { c: 48, r: 0, s: 9.0 } },

  // 5 · LOCKED on the last tab while the pointer glides in and presses it.
  //     The camera does nothing here; the subject arrives.
  { id: 'bartabs', t0: 8.30, t1: 9.35, cast: [2.90, 4.30], ease: 'lin',
    from: { c: 48, r: 0, s: 9.0 }, to: { c: 48, r: 0, s: 9.0 } },

  // 6 · TRACK LEFT with the drag. MouseDrag1Status is bound to swap-window, so
  //     the held tab trades places with each one it crosses — grok walks from
  //     the end of the bar to the front, one position per tab.
  { id: 'bartabs', t0: 9.35, t1: 12.00, cast: [4.30, 7.90], ease: 'inOutSine',
    from: { c: 48, r: 0, s: 9.0 }, to: { c: 24, r: 0, s: 6.5 } },

  // 7 · ZOOM OUT to one band — yeowoolair, alone, before the first hop.
  { id: 'nested', t0: 12.00, t1: 13.10, cast: [1.60, 2.70], ease: 'outQuart', cut: true,
    from: { c: 12, r: 0, s: 15.0 }, to: { c: 12, r: 0, s: 8.6 } },

  // 8 · The hops: ssh grimoire, then bingus. The subject moves, not the
  //     camera — it only drifts down to keep the growing stack centred.
  { id: 'nested', t0: 13.10, t1: 14.60, cast: [2.70, 9.60], ease: 'inOutCubic',
    from: { c: 12, r: 0, s: 8.6 }, to: { c: 12, r: 0.90, s: 8.6 } },

  // 8b · HOLD on all three bands — violet, acid green, cyan, one per machine
  //      in the ssh chain. The shot the whole system is about, so it gets the
  //      longest still beat in the piece.
  { id: 'nested', t0: 14.60, t1: 16.40, cast: [9.60, 12.40], ease: 'inOutCubic',
    from: { c: 12, r: 0.90, s: 8.6 }, to: { c: 12, r: 1.05, s: 8.6 } },

  // 9 · FALL down setup's checkbox gutter — ▌ [ ] ▌ repeating, the six-track
  //     picker's left edge.
  { id: 'picker', t0: 16.40, t1: 17.60, cast: [8.60, 9.20], ease: 'inOutCubic', cut: true,
    from: { c: 3.5, r: 4, s: 8.5 }, to: { c: 3.5, r: 12, s: 8.5 } },

  // 10 · TRACK RIGHT across one module row: name, local hash, service state,
  //      remote hash, status. Column alignment as rhythm.
  { id: 'picker', t0: 17.60, t1: 19.60, cast: [9.20, 10.10], ease: 'inOutCubic',
    from: { c: 3.5, r: 12, s: 8.5 }, to: { c: 52, r: 12, s: 5.0 } },

  // 11 · FALL through resume's session ledger.
  { id: 'resume', t0: 19.60, t1: 20.80, cast: [2.60, 3.80], ease: 'inOutCubic', cut: true,
    from: { c: 20, r: 5, s: 6.0 }, to: { c: 20, r: 10, s: 6.0 } },

  // 12 · TRACK RIGHT along one session: timestamp, harness, cwd, first prompt.
  { id: 'resume', t0: 20.80, t1: 22.60, cast: [3.80, 5.60], ease: 'inOutCubic',
    from: { c: 20, r: 10, s: 6.0 }, to: { c: 58, r: 10, s: 4.4 } },

  // 13 · FALL down the fleet. One straight vertical drop through five machines
  //      running the same environment, each announcing itself in its own hue,
  //      column-locked to the word `setup` so the fall lands already framed.
  { id: 'mosaic', t0: 22.60, t1: 26.20, ease: 'inOutCubic', cut: true, abs: true,
    from: { c: SETUP_ABS_COL, r: 0, s: 4.8 },
    to:   { c: SETUP_ABS_COL, r: AIR_BAR_ROW - 0.5, s: 5.4 } },

  // 14 · ZOOM IN until `setup` fills the frame again — exactly the composition
  //      of frame 0, on the same terminal at the same frozen instant.
  { id: 'return', t0: 26.20, t1: 28.00, ease: 'inOutCubic', abs: true,
    from: { c: SETUP_ABS_COL, r: AIR_BAR_ROW - 0.5, s: 5.4 },
    to:   { c: SETUP_ABS_COL, r: AIR_BAR_ROW - 0.5, s: 34 } }
];

// The cascade, in the order the camera meets them; each springs in just ahead
// of it. air_setup is frozen — it is the loop anchor and must be identical at
// both ends of the piece.
const TILES = [
  { id: 'tile_grimoire', cast: [0.30, 1.45], in: -1 },
  { id: 'tile_mac',      cast: [1.20, 4.60], in: 0.55 },
  { id: 'tile_bingus',   cast: [0.30, 1.45], in: 1.05 },
  { id: 'tile_oci',      cast: [0.30, 1.45], in: 1.45 },
  { id: 'air_setup',     cast: [PICKER_SETTLED, PICKER_SETTLED], in: 2.20 }
];
const MOSAIC_T0 = 22.60;

let G = null, META = {}, CW = 0, CH = 0;

// centre of cell (col,row) in scene space; `scene` aims in absolute cells
function pt(id, c, r) {
  const off = SCREENS[id] ? SCREENS[id].at : [0, 0];
  return { x: (off[0] + c + 0.5) * CW, y: (off[1] + r + 0.5) * CH };
}
function org(id) {
  const off = SCREENS[id].at;
  return { x: off[0] * CW, y: off[1] * CH };
}

// Recorded pointer track: [t, col, row, down]. Interpolated so the pointer
// glides between whole cells instead of stepping; `down` takes the value of
// the sample it is leaving.
function cursorAt(id, castT) {
  const track = META[id] && META[id].cursor;
  if (!track || !track.length) return null;
  if (castT < track[0][0] || castT > track[track.length - 1][0]) return null;
  let i = 0;
  while (i < track.length - 1 && track[i + 1][0] <= castT) i++;
  const a = track[i], b = track[Math.min(i + 1, track.length - 1)];
  const k = b[0] > a[0] ? clamp01((castT - a[0]) / (b[0] - a[0])) : 0;
  const off = SCREENS[id].at;
  return { x: (off[0] + lerp(a[1], b[1], k) + 0.5) * CW,
           y: (off[1] + lerp(a[2], b[2], k) + 0.5) * CH,
           down: !!a[3] };
}

const TIMELINE = {
  screens: SCREENS,
  duration: DUR,

  init(geom, meta) {
    G = geom; META = meta || {};
    const g = Object.values(geom)[0];   // one font, so one cell metric governs
    CW = g.cell.w; CH = g.cell.h;
  },

  at(t) {
    t = Math.max(0, Math.min(DUR - 1e-6, t));
    let s = SHOTS[0];
    for (const sh of SHOTS) if (t >= sh.t0) s = sh;

    const k = clamp01((t - s.t0) / (s.t1 - s.t0));
    const e = E[s.ease](k);

    // geometric zoom: a linear interpolation of scale reads as a lurch over
    // ranges this wide, so interpolate its logarithm instead
    const scale = s.from.s * Math.pow(s.to.s / s.from.s, e);

    const layers = [], castTime = {};
    let aimId = s.abs ? 'scene' : s.id;

    if (s.id === 'mosaic' || s.id === 'return') {
      const spread = t - MOSAIC_T0;
      for (const tile of TILES) {
        const p = clamp01((spread - tile.in) / 0.62);
        castTime[tile.id] = Math.min(tile.cast[1],
                                     tile.cast[0] + Math.max(0, spread - tile.in));
        layers.push({ id: tile.id, ...org(tile.id), z: 1,
                      o: clamp01(p * 1.8), s: 0.92 + 0.08 * E.outSpring(p) });
      }
    } else {
      castTime[s.id] = lerp(s.cast[0], s.cast[1], k);
      layers.push({ id: s.id, ...org(s.id), s: 1, o: 1, z: 1 });
    }

    const a = pt(aimId, s.from.c, s.from.r);
    const b = pt(aimId, s.to.c, s.to.r);
    const cam = { x: lerp(a.x, b.x, e), y: lerp(a.y, b.y, e), s: scale };
    const cursor = castTime[s.id] !== undefined ? cursorAt(s.id, castTime[s.id]) : null;

    return { cam, layers, castTime, cursor };
  }
};
