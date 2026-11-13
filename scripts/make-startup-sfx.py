#!/usr/bin/env python3
"""Write the original start-up synth tones. No sampled or filmed audio."""

import math
import struct
import wave
from pathlib import Path

RATE = 22050
OUT = Path(__file__).resolve().parents[1] / "JARVIS" / "Resources" / "Startup"


def clamp(sample: float) -> int:
    return max(-32767, min(32767, int(sample * 32767)))


def write(name: str, samples: list[float]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    with wave.open(str(path), "w") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        frames = b"".join(struct.pack("<h", clamp(sample)) for sample in samples)
        handle.writeframes(frames)
    print(f"{name} {len(samples) / RATE:.3f}s {path.stat().st_size} bytes")


def tick() -> list[float]:
    count = int(RATE * 0.045)
    samples = []
    for index in range(count):
        time = index / RATE
        envelope = math.exp(-time * 78)
        tone = math.sin(2 * math.pi * 2840 * time)
        noise = (((index * 1103515245 + 12345) & 0x7FFFFFFF) / 0x7FFFFFFF) * 2 - 1
        samples.append((tone * 0.28 + noise * 0.72) * envelope * 0.42)
    return samples


def chime() -> list[float]:
    count = int(RATE * 0.52)
    samples = []
    for index in range(count):
        time = index / RATE
        attack = min(1.0, time / 0.012)
        envelope = attack * math.exp(-time * 4.2)
        first = math.sin(2 * math.pi * 698.46 * time)
        second = math.sin(2 * math.pi * 880.0 * max(0.0, time - 0.11)) if time > 0.11 else 0.0
        partial = math.sin(2 * math.pi * 1396.9 * time) * 0.15
        samples.append((first * 0.48 + second * 0.4 + partial) * envelope * 0.34)
    return samples


def swell() -> list[float]:
    count = int(RATE * 1.75)
    samples = []
    for index in range(count):
        time = index / RATE
        rise = min(1.0, time / 1.15)
        fade = min(1.0, (1.75 - time) / 0.28)
        envelope = rise * rise * fade
        curve = time / 1.75
        frequency = 186 * ((720 / 186) ** curve)
        tone = math.sin(2 * math.pi * frequency * time)
        fifth = math.sin(2 * math.pi * frequency * 1.5 * time) * 0.22
        air = math.sin(2 * math.pi * (frequency * 2.01) * time) * 0.08
        samples.append((tone + fifth + air) * envelope * 0.3)
    return samples


if __name__ == "__main__":
    write("startup-tick.wav", tick())
    write("startup-chime.wav", chime())
    write("startup-swell.wav", swell())
