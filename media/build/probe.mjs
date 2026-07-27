import fs from 'node:fs';
import puppeteer from 'puppeteer-core';
import { serve, CHROME, CHROME_ARGS } from './serve.mjs';

// Render single frames of the timeline, for checking framing without a full run.
//   node probe.mjs "1.0,5.0,9.0" [outdir]
const FPS = 60;
const times = process.argv[2]
  ? process.argv[2].split(',').map(Number)
  : Array.from({ length: 28 }, (_, i) => i + 0.5);
const outDir = process.argv[3] || 'probe';
fs.rmSync(outDir, { recursive: true, force: true });
fs.mkdirSync(outDir, { recursive: true });

const { server, port } = await serve();
const b = await puppeteer.launch({ executablePath: CHROME, headless: true,
  protocolTimeout: 300000, args: CHROME_ARGS,
  defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 } });
const p = await b.newPage();
p.on('pageerror', e => console.log('PAGE ERR', e.message));
await p.goto(`http://127.0.0.1:${port}/stage.html`, { waitUntil: 'networkidle0' });
await p.waitForFunction('window.__ready===true', { timeout: 90000 });
console.log('total frames', await p.evaluate(() => window.__total));

let i = 0;
for (const t of times) {
  await p.evaluate(f => window.__frame(f), Math.round(t * FPS));
  fs.writeFileSync(`${outDir}/p${String(i++).padStart(2, '0')}_${t.toFixed(2)}.png`,
                   await p.screenshot({ type: 'png' }));
  process.stdout.write('.');
}
console.log(`\nwrote ${i} probes to ${outDir}/`);
await b.close(); server.close();
