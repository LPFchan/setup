import puppeteer from 'puppeteer-core';
import { serve, CHROME } from './serve.mjs';

// Step a cast at 60fps and report every frame on which the status bar's text
// changes — which is how reorder *steps* get told apart from redraw thrash.
//   node barscan.mjs <cast> [t0] [t1]
const name = process.argv[2] || 'bartabs';
const from = Number(process.argv[3] ?? 0);
const to   = Number(process.argv[4] ?? 99);

const { server, port } = await serve();
const b = await puppeteer.launch({ executablePath: CHROME, headless: true,
  protocolTimeout: 300000, args: ['--hide-scrollbars'],
  defaultViewport: { width: 1400, height: 900 } });
const p = await b.newPage();
p.on('pageerror', e => console.log('ERR', e.message));
await p.goto(`http://127.0.0.1:${port}/dump.html`, { waitUntil: 'networkidle0' });
await p.waitForFunction('window.__ready===true');
const info = await p.evaluate(n => window.__open(n), name);
console.log(`${name}: ${info.cols}x${info.rows} dur=${info.dur}s`);

let prev = null, changes = 0, last = null;
const end = Math.min(Math.round(to * 60), Math.round(info.dur * 60));
for (let f = Math.round(from * 60); f <= end; f++) {
  const t = f / 60;
  await p.evaluate(tt => window.__seek(tt), t);
  const bar = (await p.evaluate(() => window.__text()))[0]
    .replace(/\s+CPU.*$/, '').replace(/\s+$/, '');
  if (bar !== prev) {
    const gap = last === null ? '' : `  (+${(t - last).toFixed(3)}s)`;
    console.log(`  t=${t.toFixed(3)}  f=${f}  |${bar}|${gap}`);
    if (prev !== null) changes++;
    prev = bar; last = t;
  }
}
console.log(`${changes} bar changes`);
await b.close(); server.close();
