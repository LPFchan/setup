import { spawn } from 'node:child_process';
import puppeteer from 'puppeteer-core';
import { serve, CHROME, CHROME_ARGS } from './serve.mjs';

// Step the stage one frame at a time and pipe the frames to ffmpeg.
//   node render.mjs [out.mp4]
const OUT = process.argv[2] || 'master.mp4';
const FPS = 60;

const { server, port } = await serve();
const b = await puppeteer.launch({ executablePath: CHROME, headless: true,
  protocolTimeout: 600000, args: CHROME_ARGS,
  defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 } });
const p = await b.newPage();
p.on('pageerror', e => console.log('PAGE ERR', e.message));
await p.goto(`http://127.0.0.1:${port}/stage.html`, { waitUntil: 'networkidle0' });
await p.waitForFunction('window.__ready===true', { timeout: 90000 });
const total = await p.evaluate(() => window.__total);
console.log(`rendering ${total} frames @ ${FPS}fps -> ${OUT}`);

// Near-lossless master on the VideoToolbox hardware encoder; the delivery
// renditions are cut from this, so the browser only draws once.
const ff = spawn('ffmpeg', [
  '-y', '-hide_banner', '-loglevel', 'error',
  '-f', 'image2pipe', '-framerate', String(FPS), '-i', '-',
  '-c:v', 'hevc_videotoolbox', '-b:v', '90M', '-q:v', '75',
  '-pix_fmt', 'yuv420p', '-tag:v', 'hvc1', '-movflags', '+faststart', OUT
], { stdio: ['pipe', 'inherit', 'inherit'] });
ff.stdin.setMaxListeners(0);

const write = buf => new Promise((res, rej) => {
  if (ff.stdin.write(buf)) return res();
  ff.stdin.once('drain', res); ff.stdin.once('error', rej);
});

const t0 = Date.now();
for (let n = 0; n < total; n++) {
  await p.evaluate(f => window.__frame(f), n);
  await write(await p.screenshot({ type: 'png', optimizeForSpeed: true }));
  if (n % 120 === 0 || n === total - 1) {
    const el = (Date.now() - t0) / 1000;
    const eta = n ? (el / (n + 1)) * (total - n - 1) : 0;
    process.stdout.write(`\r  ${n + 1}/${total}  ${el.toFixed(0)}s elapsed  ~${eta.toFixed(0)}s left   `);
  }
}
ff.stdin.end();
await new Promise(r => ff.on('close', r));
console.log(`\ndone in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
await b.close(); server.close();
