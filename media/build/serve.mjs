import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const DIR = path.dirname(fileURLToPath(import.meta.url));
export const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const MIME = { '.html':'text/html', '.js':'text/javascript', '.mjs':'text/javascript',
               '.css':'text/css', '.json':'application/json', '.png':'image/png',
               '.mp4':'video/mp4', '.jpg':'image/jpeg' };

export async function serve(root = DIR) {
  const s = http.createServer((q, r) => {
    let u = q.url.split('?')[0];
    if (u === '/') u = '/index.html';
    const p = path.join(root, decodeURIComponent(u));
    if (!fs.existsSync(p) || fs.statSync(p).isDirectory()) { r.writeHead(404); return r.end(); }
    const size = fs.statSync(p).size, type = MIME[path.extname(p)] || 'application/octet-stream';
    const range = q.headers.range;
    if (range) {                                   // video seeking needs 206s
      const m = /bytes=(\d*)-(\d*)/.exec(range);
      const start = m[1] ? parseInt(m[1]) : 0, end = m[2] ? parseInt(m[2]) : size - 1;
      r.writeHead(206, { 'content-type': type, 'accept-ranges': 'bytes',
        'content-range': `bytes ${start}-${end}/${size}`, 'content-length': end - start + 1 });
      return fs.createReadStream(p, { start, end }).pipe(r);
    }
    r.writeHead(200, { 'content-type': type, 'accept-ranges': 'bytes', 'content-length': size });
    fs.createReadStream(p).pipe(r);
  });
  await new Promise(r => s.listen(0, '127.0.0.1', r));
  return { server: s, port: s.address().port };
}

export const CHROME_ARGS = [
  '--hide-scrollbars', '--force-color-profile=srgb', '--font-render-hinting=none',
  '--disable-lcd-text', '--use-gl=angle', '--use-angle=metal',
  '--enable-gpu-rasterization', '--disable-dev-shm-usage'
];
