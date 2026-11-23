# Background music

Contributor: Codex, for this Regina Sports contribution, 2026-10-22.

These three cues were newly composed as the explicit note sequences and synthesized
instruments in `tools/build_music.py`. Inputs are that retained score, sine harmonics,
envelopes and seeded pseudorandom percussion. No recording, external sample pack,
downloaded MIDI, voice or reference song was used. This is a documented procedural
generation record, separate from the earlier maintainer-declared AI originals.

- `menu.wav`: eight bars, 104 BPM, keys / bass / soft percussion, loops.
- `lobby.wav`: eight bars, 88 BPM, lower keys / sustained chords, loops.
- `victory.wav`: rising arpeggio and resolving chord, six seconds, plays once.

The contributor dedicates the rendered WAV outputs to the public domain under
**CC0 1.0 Universal (SPDX: CC0-1.0)**, to the extent permitted by applicable law:
https://creativecommons.org/publicdomain/zero/1.0/
The retained generation script is project code under the root MIT license.
This record describes the inputs and contribution; it does not claim exclusive
rights in commonplace chord patterns or an independent legal clearance.

Reproduce with `python tools/build_music.py`. `manifest.json` records PCM format,
duration, BPM, loop policy, peak/RMS, loop-boundary difference and output SHA-256.
No third-party synthesis dependency is required. Outputs are mono 22050 Hz 16-bit PCM;
the game routes them to the existing Music bus with a short transition fade.
