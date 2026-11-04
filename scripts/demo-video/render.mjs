// Renders stage.html frame by frame through headless Chrome (DevTools protocol), like HyperFrames:
// seek(frame) in the page, wait for its image, screenshot, repeat. Usage: node render.mjs FRAMES OUTDIR
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const [total, out] = [Number(process.argv[2]), process.argv[3]];
const here = new URL(".", import.meta.url).pathname;
mkdirSync(out, { recursive: true });

const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
  "--headless=new", "--remote-debugging-port=9333", `--user-data-dir=${mkdtempSync(join(tmpdir(), "knob-demo-"))}`, "--hide-scrollbars",
  "--allow-file-access-from-files", "--force-device-scale-factor=1", "--window-size=1280,720", "about:blank",
], { stdio: "ignore" });

let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch("http://127.0.0.1:9333/json/list")).json()).find(t => t.type === "page"); } catch {}
}
if (!target) { chrome.kill(); throw new Error("Chrome did not start"); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener("open", r, { once: true }));
let id = 0; const waiting = new Map();
ws.addEventListener("message", e => { const m = JSON.parse(e.data); if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); } });
const send = (method, params = {}) => new Promise(r => { const n = ++id; waiting.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });

await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 720, deviceScaleFactor: 1, mobile: false });
await send("Page.enable");
await send("Page.navigate", { url: `file://${here}stage.html` });
await sleep(1500);

for (let f = 0; f < total; f++) {
  const r = await send("Runtime.evaluate", { expression: `seek(${f}).then(() => document.fonts.ready).then(() => 1)`, awaitPromise: true });
  if (r.error || r.result?.exceptionDetails) { console.error("seek failed at", f, JSON.stringify(r).slice(0, 300)); break; }
  const shot = await send("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width: 1280, height: 720, scale: 1 } });
  writeFileSync(`${out}/f-${String(f).padStart(5, "0")}.png`, Buffer.from(shot.result.data, "base64"));
}
console.log(`rendered ${total} frames to ${out}`);
ws.close(); chrome.kill();
