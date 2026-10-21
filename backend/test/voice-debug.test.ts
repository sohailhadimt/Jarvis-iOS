import { describe, expect, it } from "vitest";
import { sanitizeVoiceDebug } from "../src/voice-debug";

describe("voice debug", () => {
  it("keeps a short kind and redacts a phone number", () => {
    const events = sanitizeVoiceDebug(
      {
        events: [
          { kind: "barge", detail: "stopped playback" },
          { kind: "end-of-turn", detail: "call +44 7700 900123 now" },
          { kind: "", detail: "dropped" },
          { kind: "speech began!", detail: "aec on" },
        ],
      },
      "2026-10-21T12:00:00.000Z",
    );
    expect(events).toEqual([
      { at: "2026-10-21T12:00:00.000Z", kind: "barge", detail: "stopped playback" },
      { at: "2026-10-21T12:00:00.000Z", kind: "end-of-turn", detail: "call [number] now" },
      { at: "2026-10-21T12:00:00.000Z", kind: "speechbegan", detail: "aec on" },
    ]);
  });

  it("keeps a stored timestamp", () => {
    const events = sanitizeVoiceDebug(
      {
        events: [{ kind: "speech-began", detail: "aec on", at: "2026-10-21T11:00:00.000Z" }],
      },
      "2026-10-21T12:00:00.000Z",
    );
    expect(events[0]?.at).toBe("2026-10-21T11:00:00.000Z");
  });
});
