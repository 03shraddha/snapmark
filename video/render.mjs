// Renders demo.html to PNG frames with headless Chrome. Needs Node 22 or later. No npm packages.
// Usage: node render.mjs            all frames
//        node render.mjs 8.8 20.5   only these times, for a check
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, 'build', 'frames');
const FPS = 30, SECONDS = 30, PORT = 9377;
const only = process.argv.slice(2).map(Number);

mkdirSync(out, { recursive: true });
const profile = join(here, 'build', 'chrome-profile');
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`,
  '--window-size=1920,1080', '--force-device-scale-factor=1', '--hide-scrollbars',
  '--allow-file-access-from-files', 'about:blank',
], { stdio: 'ignore' });

const sleep = ms => new Promise(r => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).find(x => x.type === 'page'); } catch {}
}
if (!target) { chrome.kill(); throw new Error('Chrome did not start'); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let seq = 0;
const waiting = new Map();
ws.addEventListener('message', e => {
  const m = JSON.parse(e.data);
  if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m.result); waiting.delete(m.id); }
});
const send = (method, params = {}) => new Promise(r => { const id = ++seq; waiting.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
const evaluate = expression => send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });

await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await send('Page.navigate', { url: 'file://' + join(here, 'demo.html') + '?t=0' });
await sleep(1500);
await evaluate(`Promise.all([document.fonts.ready, ...[...document.images].map(i => i.decode().catch(() => 0))]).then(() => document.fonts.load('600 20px Inter')).then(() => 1)`);
await sleep(500);

const times = only.length ? only : Array.from({ length: FPS * SECONDS }, (_, i) => i / FPS);
for (let i = 0; i < times.length; i++) {
  await evaluate(`render(${times[i]}); new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(1))))`);
  const { data } = await send('Page.captureScreenshot', { format: 'png' });
  const name = only.length ? `check_${times[i].toFixed(1)}.png` : `f${String(i).padStart(4, '0')}.png`;
  writeFileSync(join(out, name), Buffer.from(data, 'base64'));
  if (i % 90 === 0) console.log(`frame ${i} of ${times.length}`);
}
ws.close();
chrome.kill();
await sleep(300);
rmSync(profile, { recursive: true, force: true });
console.log('done');
