import puppeteer from 'puppeteer-core';
import fs from 'node:fs';
import { serve, CHROME, DIR } from './serve.mjs';

// Replay a cast and print the screen as text at the given times.
//   node dump.mjs <cast> [t,t,t]
const name  = process.argv[2];
const times = process.argv[3] ? process.argv[3].split(',').map(Number) : null;
if (!name) {
  console.log('casts:', fs.readdirSync(`${DIR}/casts`).map(f => f.replace('.json', '')).join(' '));
  process.exit(0);
}

const { server, port } = await serve();
const b = await puppeteer.launch({ executablePath: CHROME, headless: true,
  protocolTimeout: 300000, args: ['--hide-scrollbars'],
  defaultViewport: { width: 1600, height: 1200 } });
const p = await b.newPage();
p.on('pageerror', e => console.log('ERR', e.message));
await p.goto(`http://127.0.0.1:${port}/dump.html`, { waitUntil: 'networkidle0' });
await p.waitForFunction('window.__ready===true');

const info = await p.evaluate(n => window.__open(n), name);
console.log(`== ${name}  ${info.cols}x${info.rows}  dur=${info.dur}s`);
const ts = times || Array.from({ length: 6 }, (_, i) => +(info.dur * (i + 1) / 6).toFixed(2));

for (const t of ts) {
  await p.evaluate(tt => window.__seek(tt), t);
  const [lines, bgs] = await p.evaluate(() => [window.__text(), window.__rowbg()]);
  console.log(`\n--- t=${t}s ---`);
  lines.forEach((l, y) => {
    const bg = bgs[y];
    const tag = (typeof bg === 'string' && bg !== '#000000') ? `  <bg ${bg}>` : '';
    const text = l.replace(/\s+$/, '');
    if (text || tag) console.log(String(y).padStart(2) + '|' + text + tag);
  });
}
await b.close(); server.close();
