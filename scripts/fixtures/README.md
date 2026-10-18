# Intro recognition fixtures

`intro-calibration-fingerprints.json` contains hashes extracted from local media
with the production `IntroFrameHasher`, using `IntroFingerprintProbe.extract`.
It contains no frames, video, filesystem paths or Plex credentials.

- Apothecary Diaries episodes 2, 3 and 12 share opening `a`; episodes 13 and 14
  share opening `b`. Each has captures at 0, 0.125 and 0.25 seconds relative to
  its Plex intro marker, exercising different sampling phases.
- Twelve unrelated openings (anime and live action) provide negative controls.
  Their labels identify distinct openings, not similarity clusters inferred by
  the matcher. No negative control is treated as a positive repeat.
- Each recording covers fourteen seconds from its capture phase, at four frames
  per second. Blank or insufficiently structured frames are excluded by the
  production quality gate.
- `algorithmVersion` must match the production descriptor version. A point has
  marker-relative `time`, two unsigned 64-bit gradient hashes, `quality` and
  timestamp `uncertainty`. The offline decoder uses zero timing uncertainty.

Run `scripts/probe-intro-fingerprints.sh` from any working directory. It compiles
the production core and checks every recording against each other episode's
phase-zero reference: 24 repeat pairs and 408 different-opening pairs. It also
checks the persisted 12 → 13 → 14 viewing sequence at all three phases.

`apothecary-intros.json` supplies local filenames and Plex marker ranges for fresh
decoding. Pass it and the season directory as the two arguments to the probe;
this requires ffmpeg and access to those files. This mode uses full openings as
references and fourteen-second queries, and checks both image adapters.
The probe's `Calibration` and `FrameExtraction` constants name its corpus
requirements, latency bounds, capture phases, and image extraction settings.
Expected calibration bounds stay independent of production tuning so a runtime
change cannot silently relax a regression check.

These are regression and calibration examples, not an estimate of the global
false-match rate. Capture timing on a device still depends on the engine.
