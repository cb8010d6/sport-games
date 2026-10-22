"""Render this contribution's three original synthesized cues; no external samples.

Python standard library only. Scores and synthesis are retained here under MIT.
Rendered WAV outputs are dedicated under CC0-1.0; see assets/music/CREDITS.md.
"""
from __future__ import annotations

import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import random
import sys
import wave

RATE = 22050
CHORDS = ((60, 64, 67, 71), (53, 57, 60, 64), (57, 60, 64, 67), (55, 59, 62, 67))
MELODIES = ((72, 76, 79, 76, 74, 79, 76, 71), (72, 77, 76, 72, 69, 72, 76, 77),
            (76, 72, 69, 72, 76, 79, 76, 72), (74, 79, 77, 74, 71, 74, 79, 74))


def note(buffer: list[float], start: float, length: float, midi: int, gain: float, voice: str) -> None:
    frequency = 440.0 * 2.0 ** ((midi - 69) / 12.0)
    offset = round(start * RATE)
    count = round(length * RATE)
    for i in range(count):
        t = i / RATE
        angle = math.tau * frequency * t
        attack = min(t / 0.008, 1.0)
        release = min((count - i - 1) / (RATE * 0.07), 1.0)
        if voice == "pad":
            sound = math.sin(angle) + 0.12 * math.sin(angle * 2)
            envelope = min(t / 0.08, 1.0) * release
        elif voice == "bass":
            sound = math.sin(angle) + 0.22 * math.sin(angle * 2)
            envelope = attack * release * math.exp(-t * 3.0)
        else:
            sound = math.sin(angle) + 0.25 * math.sin(angle * 2) + 0.08 * math.sin(angle * 3)
            envelope = attack * release * math.exp(-t * 5.0)
        if offset + i < len(buffer):
            buffer[offset + i] += gain * sound * envelope


def drum(buffer: list[float], start: float, kick: bool, rng: random.Random) -> None:
    offset = round(start * RATE)
    for i in range(round(RATE * 0.18)):
        if offset + i >= len(buffer):
            break
        t = i / RATE
        if kick:
            phase = math.tau * (48 * t + 1.8 * (1 - math.exp(-t * 35)))
            sound = math.sin(phase) * math.exp(-t * 24) * min(t / 0.003, 1.0) * 0.12
        else:
            sound = rng.uniform(-1, 1) * math.exp(-t * 65) * min(t / 0.002, 1.0) * 0.022
        buffer[offset + i] += sound


def compose(track: str) -> tuple[list[float], dict]:
    bpm = {"menu": 104, "lobby": 88, "victory": 120}[track]
    beat = 60.0 / bpm
    loop = track != "victory"
    duration = 32 * beat if loop else 6.0
    buffer = [0.0] * round(duration * RATE)
    rng = random.Random(20261022)
    if loop:
        for bar in range(8):
            chord_index = bar % 4 if track == "menu" else (bar + 2) % 4
            chord = CHORDS[chord_index]
            start = bar * 4 * beat
            for pitch in chord:
                note(buffer, start, 3.9 * beat, pitch, 0.026, "pad")
            for step in range(4):
                note(buffer, start + step * beat, beat * 0.72, chord[0] - 24, 0.16, "bass")
                drum(buffer, start + step * beat, step % 2 == 0, rng)
            melody = MELODIES[chord_index]
            for step in range(8 if track == "menu" else 4):
                pitch = melody[step] if track == "menu" else melody[step * 2] - 12
                note(buffer, start + step * beat * (0.5 if track == "menu" else 1.0),
                     beat * 0.7, pitch, 0.14 if track == "menu" else 0.12, "keys")
    else:
        for step, pitch in enumerate((67, 71, 74, 79, 72, 76, 79, 84)):
            note(buffer, step * beat * 0.5, 0.8, pitch, 0.19, "keys")
        for pitch in (48, 60, 64, 67, 72):
            note(buffer, 2.0, 3.5, pitch, 0.06, "pad")
    dry = buffer.copy()
    for seconds, gain in ((0.13, 0.15), (0.23, 0.10), (0.37, 0.06)):
        delay = round(seconds * RATE)
        for i, sample in enumerate(dry):
            target = i + delay
            if target < len(buffer) or loop:
                buffer[target % len(buffer)] += sample * gain
    peak = max(abs(sample) for sample in buffer)
    buffer = [sample * 0.78 / peak for sample in buffer]
    if loop:
        # A short boundary taper also covers the wrapped reverb tail, avoiding a
        # discontinuity when the PCM cursor wraps to the first sample.
        edge = round(0.012 * RATE)
        for i in range(edge):
            gain = i / edge
            buffer[i] *= gain
            buffer[-i - 1] *= gain
    return buffer, {"bpm": bpm, "loop": loop, "seconds": len(buffer) / RATE}


def render(output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"sample_rate": RATE, "channels": 1, "bits": 16, "license": "CC0-1.0", "tracks": {}}
    for track in ("menu", "lobby", "victory"):
        samples, metadata = compose(track)
        pcm = array("h", (round(sample * 32767) for sample in samples))
        if sys.byteorder != "little":
            pcm.byteswap()
        path = output / (track + ".wav")
        with wave.open(str(path), "wb") as writer:
            writer.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
            writer.writeframes(pcm.tobytes())
        metadata.update(sha256=hashlib.sha256(path.read_bytes()).hexdigest(), bytes=path.stat().st_size,
                        peak=max(abs(sample) for sample in samples),
                        rms=math.sqrt(sum(sample * sample for sample in samples) / len(samples)),
                        seam=abs(samples[0] - samples[-1]))
        manifest["tracks"][track] = metadata
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "game/assets/music")
    args = parser.parse_args()
    print(json.dumps(render(args.output), indent=2))


if __name__ == "__main__":
    main()
