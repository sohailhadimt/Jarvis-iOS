#!/usr/bin/env node
// Bundles the five start-up lines in the George voice when ELEVENLABS_API_KEY is set.
// A missing key is not an error: the app caches the lines on the first launch that has a saved key.
// The key is never printed.

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const lines = [
  ["startup-voice-morning.mp3", "Good morning, Sir. J.A.R.V.I.S. online."],
  ["startup-voice-afternoon.mp3", "Good afternoon, Sir. J.A.R.V.I.S. online."],
  ["startup-voice-evening.mp3", "Good evening, Sir. J.A.R.V.I.S. online."],
  ["startup-voice-preferences.mp3", "Loading your preferences."],
  ["startup-voice-operational.mp3", "All systems are operational."],
];

const voiceID = "JBFqnCBsd6RMkjVDRZzb";
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "JARVIS", "Resources", "Startup");
const key = process.env.ELEVENLABS_API_KEY || "";

if (!key) {
  console.log("ELEVENLABS_API_KEY is not set. Startup speech will cache on first launch.");
  process.exit(0);
}

try {
await mkdir(root, { recursive: true });

async function synthesize(text, model) {
  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceID}?output_format=mp3_44100_128`,
    {
      method: "POST",
      headers: {
        "xi-api-key": key,
        "Content-Type": "application/json",
        Accept: "audio/mpeg",
      },
      body: JSON.stringify({
        text,
        model_id: model,
        voice_settings: { stability: 0.5, similarity_boost: 0.75 },
      }),
    }
  );
  if (!response.ok) {
    return { ok: false, status: response.status };
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length < 400) return { ok: false, status: response.status };
  return { ok: true, bytes };
}

let failed = 0;
for (const [name, text] of lines) {
  let result = await synthesize(text, "eleven_turbo_v2_5");
  if (!result.ok) result = await synthesize(text, "eleven_flash_v2_5");
  if (!result.ok) {
    failed += 1;
    console.log(`${name} skipped (HTTP ${result.status})`);
    continue;
  }
  await writeFile(join(root, name), result.bytes);
  console.log(`${name} ${result.bytes.length} bytes`);
}

if (failed === lines.length) {
  console.log("Startup voice was not bundled. The app will cache it on first launch.");
}
} catch {
  console.log("Startup voice was not bundled. The app will cache it on first launch.");
}
