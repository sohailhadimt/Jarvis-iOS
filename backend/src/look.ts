import { dbAll, dbFirst, dbRun } from "./db";
import { json, newId, nowIso } from "./http";
import type { Env } from "./types";

/** "Let me show you": a short-lived, owner-only camera / screen page. */
export const LOOK_MINUTES = 30;
const MAX_ASKS = 200;
const MAX_IMAGE_B64 = 3_000_000;

const readyDbs = new WeakSet<object>();

async function ensureLookTable(env: Env): Promise<void> {
  if (readyDbs.has(env.DB as object)) return;
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS look_links (
      token TEXT PRIMARY KEY,
      phone TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      asks INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL
    )`,
  );
  readyDbs.add(env.DB as object);
}

/** "let me show you", "can you see this", "look at this", "camera". No media attached. */
export function wantsToShow(text: string): boolean {
  const t = text.toLowerCase().replace(/\s+/g, " ").trim();
  if (/\b(?:let me|lemme|i(?:'ll| will| wanna| want to)|can i) (?:show|show you)\b/.test(t)) return true;
  if (/\b(?:can|could) (?:u|you) (?:see|look at) (?:this|that|it|my (?:screen|camera))\b/.test(t)) return true;
  if (/\b(?:camera|screen ?share|share (?:my|the) screen|video ?call|facetime)\b/.test(t) && /\b(?:link|open|send|start|show|share|use|let|want|can)\b/.test(t)) return true;
  return /^(?:look at this|camera|camera link|show you)[.!?]*$/.test(t);
}

function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(18));
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function createLookLink(env: Env, phone: string, origin: string, now = new Date()): Promise<{ token: string; url: string; expires: string }> {
  await ensureLookTable(env);
  const token = randomToken();
  const expires = new Date(now.getTime() + LOOK_MINUTES * 60_000).toISOString();
  await dbRun(env, "INSERT INTO look_links (token, phone, expires_at, asks, created_at) VALUES (?, ?, ?, 0, ?)", [token, phone, expires, now.toISOString()]);
  await dbRun(env, "DELETE FROM look_links WHERE expires_at < ?", [new Date(now.getTime() - 86_400_000).toISOString()]).catch(() => 0);
  return { token, url: `${origin.replace(/\/+$/, "")}/look/${token}`, expires };
}

export function lookLinkText(url: string): string {
  return `Open this and point your camera at it, Sir: ${url}\nTap the mic and talk; I'll answer out loud. Works for ${LOOK_MINUTES} minutes, just for you.`;
}

async function lookRow(env: Env, token: string, now = new Date()): Promise<{ phone: string; asks: number } | null> {
  if (!/^[0-9a-f]{36}$/.test(token)) return null;
  await ensureLookTable(env);
  const row = await dbFirst<{ phone: string; asks: number; expires_at: string }>(env, "SELECT phone, asks, expires_at FROM look_links WHERE token = ?", [token]);
  if (!row || row.expires_at < now.toISOString()) return null;
  return { phone: row.phone, asks: row.asks };
}

const LOOK_PROMPT =
  "You are J.A.R.V.I.S., Sir's British assistant, live on a video call: you see what his phone camera (or his screen or a screenshot) shows right now and he hears your reply spoken aloud. Answer his question about what you see directly and naturally, like a person looking over his shoulder: name what it is, read any text or numbers he needs, and say what to do next. If the picture is too dark, blurry or doesn't show it, say so and tell him how to point the camera. Never invent details you can't see. Spoken English, no markdown, no lists, under 60 words. Call him Sir at most once.";

function parseImage(dataUrl: unknown): { mime: string; b64: string } | null {
  if (typeof dataUrl !== "string") return null;
  const m = /^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/=]+)$/.exec(dataUrl);
  if (!m || m[2]!.length < 200 || m[2]!.length > MAX_IMAGE_B64) return null;
  return { mime: m[1]!, b64: m[2]! };
}

async function speakQuick(env: Env, text: string): Promise<string | null> {
  const key = (env.ELEVENLABS_API_KEY ?? "").trim();
  if (!key || !text) return null;
  const { GEORGE_VOICE_ID } = await import("./brain");
  try {
    const response = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${GEORGE_VOICE_ID}?output_format=mp3_44100_64`, {
      method: "POST",
      headers: { "xi-api-key": key, "content-type": "application/json" },
      body: JSON.stringify({ text: text.slice(0, 400), model_id: "eleven_flash_v2_5" }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length < 1_000) return null;
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  } catch {
    return null;
  }
}

function simulated(phone: string): boolean {
  return /^\+447700900\d{3}$/.test(phone);
}

async function rememberLook(env: Env, phone: string, role: "user" | "assistant", body: string): Promise<void> {
  await dbRun(env, "INSERT INTO sms_turns (id, phone, role, body, created_at) VALUES (?, ?, ?, ?, ?)", [newId("sms"), phone, role, body.slice(0, 1000), nowIso()]);
  if (simulated(phone)) return;
  const { rememberLine } = await import("./brain");
  await rememberLine(env, { source: "sms", role, body }).catch(() => undefined);
}

export async function lookAsk(env: Env, token: string, body: Record<string, unknown>): Promise<Response> {
  const row = await lookRow(env, token);
  if (!row) return json({ ok: false, error: "This link has expired, Sir. Ask me for a new one." }, 410);
  if (row.asks >= MAX_ASKS) return json({ ok: false, error: "That's the limit for this link, Sir. Ask me for a new one." }, 429);
  const question = (typeof body.question === "string" ? body.question : "").replace(/\s+/g, " ").trim().slice(0, 500);
  const image = parseImage(body.image);
  if (!question && !image) return json({ ok: false, error: "Nothing to look at yet." }, 400);
  await dbRun(env, "UPDATE look_links SET asks = asks + 1 WHERE token = ?", [token]);
  const recent = await dbAll<{ role: string; body: string }>(
    env,
    "SELECT role, body FROM sms_turns WHERE phone = ? ORDER BY created_at DESC, rowid DESC LIMIT 6",
    [row.phone],
  ).catch(() => []);
  const history = recent
    .reverse()
    .filter((t) => (t.role === "user" || t.role === "assistant") && t.body)
    .map((t) => ({ role: t.role as "user" | "assistant", content: t.body.slice(0, 400) }));
  const { describeImage } = await import("./sms-extras");
  const asked = question || "What can you see?";
  const answer =
    (await describeImage(env, image, asked, { prompt: LOOK_PROMPT, maxChars: 420, history })) ??
    "I can't see it clearly just now, Sir; my vision service isn't answering. Try again in a moment.";
  await rememberLook(env, row.phone, "user", `[camera] ${asked}`).catch(() => undefined);
  await rememberLook(env, row.phone, "assistant", answer).catch(() => undefined);
  const audio = body.voice === false ? null : await speakQuick(env, answer);
  return json({ ok: true, answer, audio });
}

export function isLookRoute(method: string, path: string): boolean {
  return (method === "GET" && /^\/look\/[0-9a-f]{36}$/.test(path)) || (method === "POST" && /^\/look\/[0-9a-f]{36}\/ask$/.test(path));
}

export async function handleLook(request: Request, env: Env, path: string): Promise<Response> {
  const token = path.split("/")[2] ?? "";
  if (request.method === "POST") {
    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
    return lookAsk(env, token, body ?? {});
  }
  const row = await lookRow(env, token);
  const headers = {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
    "x-robots-tag": "noindex",
    "permissions-policy": "camera=(self), microphone=(self), display-capture=(self)",
  };
  if (!row) return new Response(expiredPage(), { status: 410, headers });
  return new Response(lookPage(token), { status: 200, headers });
}

function expiredPage(): string {
  return `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>JARVIS</title><body style="background:#05080d;color:#cfe;font:17px -apple-system,sans-serif;padding:32px">This link has expired, Sir. Text JARVIS "let me show you" for a fresh one.</body>`;
}

export function lookPage(token: string): string {
  return `<!doctype html>
<html lang="en-GB"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>JARVIS: show me</title>
<style>
body{margin:0;background:#05080d;color:#d8f3ff;font:16px -apple-system,system-ui,sans-serif}
#stage{position:relative;width:100%;height:58vh;background:#000;overflow:hidden}
video,#shot{width:100%;height:100%;object-fit:contain;display:block}
#shot{display:none;position:absolute;inset:0}
#bar{display:flex;flex-wrap:wrap;gap:8px;padding:10px}
button,label.btn{flex:1 1 30%;background:#0d2230;color:#bfefff;border:1px solid #1e5672;border-radius:12px;padding:12px 6px;font-size:15px;text-align:center}
button.on{background:#14506e;color:#fff}
#mic{flex-basis:100%;font-size:18px;padding:16px}
#ask{display:flex;gap:8px;padding:0 10px}
#q{flex:1;background:#0a141c;color:#e8f8ff;border:1px solid #1e5672;border-radius:10px;padding:10px;font-size:16px}
#log{padding:10px;font-size:15px;line-height:1.4}
.me{color:#8fb3c4}.jv{color:#e9fbff;margin-bottom:8px}
#note{padding:0 10px;color:#7fa3b5;font-size:13px}
</style></head><body>
<div id="stage"><video id="cam" playsinline autoplay muted></video><img id="shot" alt=""></div>
<div id="bar">
<button id="flip">Flip camera</button>
<button id="screen">Share screen</button>
<label class="btn">Screenshot<input id="file" type="file" accept="image/*" hidden></label>
<button id="mic">Tap to talk</button>
</div>
<form id="ask"><input id="q" placeholder="Or type a question" autocomplete="off"><button style="flex:0 0 70px">Ask</button></form>
<div id="note"></div>
<div id="log"></div>
<canvas id="c" hidden></canvas>
<script>
const T=${JSON.stringify(token)};
const $=id=>document.getElementById(id);
const cam=$("cam"),shot=$("shot"),note=$("note"),log=$("log");
let facing="environment",stream=null,mode="camera",shotData=null,busy=false,player=new Audio();
async function startCam(){
  try{ if(stream) stream.getTracks().forEach(t=>t.stop());
    stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:facing,width:{ideal:1280}},audio:false});
    cam.srcObject=stream; mode="camera"; shot.style.display="none"; cam.style.display="block"; note.textContent="";
  }catch(e){ note.textContent="Camera blocked. Allow camera access for this page in Safari settings, or send a screenshot instead."; }
}
$("flip").onclick=()=>{facing=facing==="environment"?"user":"environment";startCam();};
const canShare=!!(navigator.mediaDevices&&navigator.mediaDevices.getDisplayMedia);
$("screen").onclick=async()=>{
  if(!canShare){ note.textContent="iPhone Safari can't share your screen with a web page. Take a screenshot and tap Screenshot instead."; return; }
  try{ if(stream) stream.getTracks().forEach(t=>t.stop());
    stream=await navigator.mediaDevices.getDisplayMedia({video:true,audio:false}); cam.srcObject=stream; mode="screen";
    shot.style.display="none"; cam.style.display="block";
    stream.getVideoTracks()[0].onended=()=>startCam();
  }catch(e){ note.textContent="Screen share was cancelled."; }
};
$("file").onchange=e=>{
  const f=e.target.files[0]; if(!f) return;
  const img=new Image(); img.onload=()=>{ shotData=frame(img,img.naturalWidth,img.naturalHeight); shot.src=shotData; shot.style.display="block"; mode="shot"; ask("What's on this screenshot?"); };
  img.src=URL.createObjectURL(f);
};
function frame(src,w,h){
  if(!w||!h) return null; const s=Math.min(1,1024/Math.max(w,h)); const c=$("c");
  c.width=Math.round(w*s); c.height=Math.round(h*s); c.getContext("2d").drawImage(src,0,0,c.width,c.height);
  return c.toDataURL("image/jpeg",0.72);
}
function current(){ return mode==="shot"?shotData:frame(cam,cam.videoWidth,cam.videoHeight); }
function add(cls,text){ const d=document.createElement("div"); d.className=cls; d.textContent=text; log.prepend(d); }
function say(text,audio){
  if(audio){ player.src="data:audio/mpeg;base64,"+audio; player.play().catch(()=>speakLocal(text)); }
  else speakLocal(text);
}
function speakLocal(text){ try{ const u=new SpeechSynthesisUtterance(text); u.lang="en-GB"; speechSynthesis.cancel(); speechSynthesis.speak(u);}catch(e){} }
async function ask(q){
  if(busy) return; busy=true; $("mic").textContent="Looking…";
  add("me",q);
  try{
    const r=await fetch("/look/"+T+"/ask",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({question:q,image:current()})});
    const d=await r.json(); const a=d.answer||d.error||"Something went wrong, Sir.";
    add("jv",a); say(a,d.audio);
  }catch(e){ add("jv","I lost the connection, Sir. Check your signal and try again."); }
  busy=false; $("mic").textContent="Tap to talk";
}
function unlock(){ player.src="data:audio/mpeg;base64,SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU4Ljc2LjEwMAAAAAAAAAAAAAAA//tQxAADB8AhSmxhIIEVCSiJrDCQBTcu3UrAIwUdkRgQbFAZC1CQEwTJ9mjRvBA4UOLD8nKVOWfh+UlK3z/177OXrfOdKl7pyn3Xf//WreyTRUoAWgBgkOAGbZHBgG1OF6zM82DWbZaUmMBptgQhGjsyYqc9ae9XFz280948NMBWInljyzsNRFLPWdnZGWrddDsjK1unuSrVN9jJsK8KuQtQCtMBjCEtImISdNKJOopIpBFpNSMbIHCSRpRR5iakjTiyzLhchUUBwCgyKiweBv/7UsQbg8isVNoMPMjAAAA0gAAABEVFGmgqK////9bP/6XCykxBTUUzLjEwMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"; player.play().catch(()=>{}); try{speechSynthesis.speak(new SpeechSynthesisUtterance(""));}catch(e){} }
const SR=window.SpeechRecognition||window.webkitSpeechRecognition;
$("mic").onclick=()=>{
  unlock();
  if(!SR){ note.textContent="Voice input isn't available in this browser; type your question below."; $("q").focus(); return; }
  const rec=new SR(); rec.lang="en-GB"; rec.interimResults=false; rec.maxAlternatives=1;
  $("mic").textContent="Listening…"; $("mic").classList.add("on");
  rec.onresult=e=>{ const t=e.results[0][0].transcript.trim(); if(t) ask(t); };
  rec.onerror=()=>{ note.textContent="I didn't catch that, Sir. Tap and try again, or type it."; };
  rec.onend=()=>{ $("mic").classList.remove("on"); if(!busy) $("mic").textContent="Tap to talk"; };
  rec.start();
};
$("ask").onsubmit=e=>{ e.preventDefault(); unlock(); const q=$("q").value.trim(); if(q){ $("q").value=""; ask(q);} };
if(!canShare) $("screen").textContent="Screen (not on iPhone)";
startCam();
</script></body></html>`;
}
