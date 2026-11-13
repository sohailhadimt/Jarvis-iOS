import { describe, expect, it } from "vitest";
import {
  agentAudioForTwilio,
  initiationMessage,
  readElevenEvent,
  redactDebug,
  streamTwiml,
  summaryFromLines,
  userAudioForEleven,
} from "../src/stream";

function b64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function unb64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

describe("media bridge", () => {
  it("passes μ-law 8k through and converts pcm 16k both ways", () => {
    const mulaw = new Uint8Array(160).fill(0xff);
    const payload = b64(mulaw);
    expect(userAudioForEleven(payload, "ulaw_8000")).toBe(payload);
    expect(agentAudioForTwilio(payload, "ulaw_8000")).toBe(payload);
    const pcm = userAudioForEleven(payload, "pcm_16000");
    expect(unb64(pcm).length).toBe(640);
    expect(unb64(agentAudioForTwilio(pcm, "pcm_16000")).length).toBe(160);
  });

  it("answers pings, clears on interruption, and reads both transcripts", () => {
    expect(readElevenEvent({ type: "ping", ping_event: { event_id: 7 } })).toEqual({ kind: "pong", eventId: 7 });
    expect(readElevenEvent({ type: "interruption", interruption_event: { event_id: 1 } })).toEqual({ kind: "clear" });
    expect(
      readElevenEvent({
        type: "user_transcript",
        user_transcription_event: { user_transcript: "This is Sam.", event_id: 2 },
      }),
    ).toEqual({ kind: "transcript", role: "them", text: "This is Sam." });
    expect(
      readElevenEvent({
        type: "agent_response",
        agent_response_event: { agent_response: "I'll pass that to Master Hadi and get back to you.", event_id: 3 },
      }).kind,
    ).toBe("transcript");
  });

  it("asks George to speak the screening line", () => {
    const raw = initiationMessage({
      callId: "call_abc",
      first: "Hello, you've reached Master Hadi's phone.",
      prompt: "Take a message.",
      overrides: true,
    });
    const body = JSON.parse(raw) as {
      conversation_config_override: { agent: { first_message: string }; tts: { voice_id: string } };
    };
    expect(body.conversation_config_override.agent.first_message).toContain("Master Hadi");
    expect(body.conversation_config_override.tts.voice_id).toBe("JBFqnCBsd6RMkjVDRZzb");
    expect(raw).not.toContain("http");
  });

  it("keeps the caller on the line when the bridge is the fallback", () => {
    const xml = streamTwiml({
      streamUrl: "wss://jarvis.example/calls/stream/call_abc",
      say: "Please leave your name and a message after the tone.",
      voice: "Polly.Brian-Neural",
      voicemailUrl: "https://jarvis.example/calls/voicemail/call_abc",
    });
    expect(xml.indexOf("<Connect>")).toBeLessThan(xml.indexOf("<Say"));
    expect(xml.indexOf("<Record")).toBeLessThan(xml.indexOf("<Hangup"));
    expect(xml).toContain("wss://jarvis.example/calls/stream/call_abc");
    expect(xml).not.toContain("can't continue");
  });

  it("summarises what they said and strips secrets", () => {
    expect(summaryFromLines([{ role: "them", text: "Sam calling about the booking." }])).toContain("booking");
    expect(summaryFromLines([])).toContain("didn't catch");
    const hidden = redactDebug("failed +447700900123 token abcdefghijklmnopqrstuvwxyz012345");
    expect(hidden).not.toContain("+447");
    expect(hidden).not.toContain("abcdefghijklmnopqrstuvwxyz");
  });
});
