#!/usr/bin/env node
// Render an HTML file to a JPG with headless Chrome, sized to its content.
//   node render.mjs <in.html> [out.jpg] [--width 1200] [--scale 2]
// No npm dependencies: talks to Chrome over the DevTools protocol using
// Node's built-in WebSocket (Node 22+).
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = args.indexOf(name);
  if (i === -1) return fallback;
  const [, value] = args.splice(i, 2);
  return Number(value);
};
const width = flag('--width', 1200);
const scale = flag('--scale', 2);
const [input, output = input?.replace(/\.html?$/i, '') + '.jpg'] = args;
if (!input || !existsSync(input)) {
  console.error('usage: render.mjs <in.html> [out.jpg] [--width 1200] [--scale 2]');
  process.exit(2);
}

const chrome = [
  process.env.SKETCH_CHROME,
  '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium', '/usr/bin/chromium-browser', '/snap/bin/chromium',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
].find(p => p && existsSync(p));
if (!chrome) {
  console.error('render.mjs: no Chrome/Chromium found (set SKETCH_CHROME)');
  process.exit(1);
}

const profile = mkdtempSync(join(tmpdir(), 'sketch-'));
const proc = spawn(chrome, [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  '--no-default-browser-check', '--remote-debugging-port=0',
  `--user-data-dir=${profile}`, 'about:blank',
], { stdio: ['ignore', 'ignore', 'pipe'] });

const exited = new Promise(ok => proc.on('exit', ok));
// Chrome's helper processes can hold the profile for a moment after it exits.
const cleanup = async () => {
  proc.kill();
  await exited;
  for (let i = 0; ; i++) {
    try { return rmSync(profile, { recursive: true, force: true }); }
    catch (e) { if (i === 20) throw e; await new Promise(r => setTimeout(r, 100)); }
  }
};
const timer = setTimeout(async () => { console.error('render.mjs: timed out'); await cleanup(); process.exit(1); }, 30000);

// Chrome prints its DevTools address on stderr once it is ready.
const wsUrl = await new Promise((ok, fail) => {
  let buf = '';
  proc.stderr.on('data', d => {
    buf += d;
    const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
    if (m) ok(m[1]);
  });
  proc.on('exit', code => fail(new Error(`chrome exited (${code}):\n${buf}`)));
});

const ws = new WebSocket(wsUrl);
await new Promise(ok => ws.addEventListener('open', ok, { once: true }));
let nextId = 0;
const pending = new Map();
const events = [];
ws.addEventListener('message', ({ data }) => {
  const msg = JSON.parse(data);
  if (msg.id && pending.has(msg.id)) {
    const { ok, fail } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? fail(new Error(msg.error.message)) : ok(msg.result);
  } else if (msg.method) {
    events.forEach(f => f(msg));
  }
});
const send = (method, params = {}, sessionId) => new Promise((ok, fail) => {
  const id = ++nextId;
  pending.set(id, { ok, fail });
  ws.send(JSON.stringify({ id, method, params, sessionId }));
});

try {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const page = (method, params) => send(method, params, sessionId);
  const evaluate = async expression =>
    (await page('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })).result.value;
  const viewport = height =>
    page('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: scale, mobile: false });

  await page('Page.enable');
  await viewport(800);
  const loaded = new Promise(ok => events.push(m => m.method === 'Page.loadEventFired' && ok()));
  await page('Page.navigate', { url: pathToFileURL(resolve(input)).href });
  await loaded;
  await evaluate('document.fonts.ready.then(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))))');

  // Crop to <body> plus its margins, so a shrink-wrapped body gives a tight image.
  const [w, h] = await evaluate(`(() => {
    const r = document.body.getBoundingClientRect(), cs = getComputedStyle(document.body);
    return [r.right + parseFloat(cs.marginRight), r.bottom + parseFloat(cs.marginBottom)];
  })()`);
  const { data } = await page('Page.captureScreenshot', {
    format: 'jpeg', quality: 92, captureBeyondViewport: true,
    clip: { x: 0, y: 0, width: Math.ceil(w), height: Math.ceil(h), scale: 1 },
  });
  writeFileSync(output, Buffer.from(data, 'base64'));
  console.log(resolve(output));
} finally {
  clearTimeout(timer);
  ws.close();
  await cleanup();
}
