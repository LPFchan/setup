import fs from 'node:fs';
import puppeteer from 'puppeteer-core';
import { serve, CHROME, CHROME_ARGS, DIR } from './serve.mjs';
import path from 'node:path';

// Screenshot the real page with the real video behind it, at chosen times.
const REPO = path.resolve(DIR, '..', '..');
const { server, port } = await serve(REPO);
const b = await puppeteer.launch({ executablePath: CHROME, headless: true,
  protocolTimeout: 120000,
  args: [...CHROME_ARGS, '--autoplay-policy=no-user-gesture-required'],
  defaultViewport: { width: 1440, height: 900 } });
const p = await b.newPage();
await p.goto(`http://127.0.0.1:${port}/index.html`, { waitUntil: 'domcontentloaded' });
await new Promise(r => setTimeout(r, 3500));
console.log(await p.evaluate(() => { const v = document.querySelector('video');
  return { w: v.videoWidth, h: v.videoHeight, err: v.error && v.error.code, src: v.currentSrc }; }));
let i = 0;
for (const t of (process.argv[2] || '0.2,4.5,9.8,15.2,20.5,25.0').split(',').map(Number)) {
  await p.evaluate(async tt => { const v = document.querySelector('video'); v.pause();
    await new Promise(res => { v.addEventListener('seeked', res, { once: true }); v.currentTime = tt; }); }, t);
  await new Promise(r => setTimeout(r, 500));
  fs.writeFileSync(`${DIR}/site_${i++}_${t}.png`, await p.screenshot({ type: 'png' }));
}
await b.close(); server.close(); console.log('ok');
