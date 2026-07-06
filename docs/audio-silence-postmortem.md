# Post-mortem: The VLCKit Silent-Audio Saga (2026-07)

> **2026-07-06 addendum — the stack this describes was retired.** Dusk moved
> from the self-built, self-patched VLCKit `4.0.0a19` (libvlc 4.0-dev) to
> VideoLAN's official prebuilt **stable MobileVLCKit/TVVLCKit 3.7.3**
> (libvlc 3.0.23), whose field-proven audiounit output has none of the
> rewritten-aout failure modes below. Consequences:
> - the local libvlc patch series (`ci_scripts/vlc-patches/`, 0013–0016) was
>   deleted with the source-build script; it lives in git history;
> - the app-side pause→play **audio revive is DORMANT** by default, gated on
>   the `vlcAudioReviveEnabled` user default (`VLCKitEngine`). It stays
>   compiled as the only proven cure for undetectable silent-render states —
>   re-arm it on device without a rebuild if silence is ever observed again;
> - TrueHD/MLP is undecodable again (stock builds disable it for App Store
>   licensing); the undecodable-track transcode fallback covers it;
> - the stale-embed guard now compares Mach-O UUIDs
>   (`scripts/verify_embedded_vlckit.sh`) and the runtime audit reports the
>   loaded libvlc version instead of a patch marker string.
>
> The diagnostic tooling (libvlc log bridge, Playback Info rows, capture
> procedure) survives the migration and remains the way to debug audio.

Read this BEFORE touching VLCKit audio, playback recovery, or anything gated
on "steady playback". It documents what was actually broken, what was chased
for months without being the cause, and the diagnostic tooling that now
exists so nobody has to re-derive it.

## Symptom

On iOS/iPadOS VLCKit playback (network streams especially): ~90% of sessions
started with video playing and **no audio at all**; double-tap seeking far
also killed audio. A manual pause→play always restored it, then playback was
perfect. No error, warning, or interruption appeared anywhere — the entire
pipeline (decoder, output bring-up, render callback, clock) reported healthy
while the speaker emitted silence. Confirmed by unified-log capture of
failing sessions on device (2026-07-05).

## The three real bugs (in causal order)

1. **The "steady playback" gate could never open on network streams.**
   `steadyPlaybackTicks` required 4 consecutive advancing time ticks while
   `!isBuffering`, and was reset on every buffering state event. But libvlc
   emits buffering state events **continuously** during network playback
   (cache-level churn) — the counter was mathematically pinned at zero.
   Everything gated on it silently never ran:
   - the automatic audio-track-selection safety net
     (`isReadyForAutomaticAudioSelection`) — never ran on network streams,
     across its entire history. This is why audio-track behavior always felt
     haunted and why earlier "deferred selection" fixes changed nothing;
   - the app-side audio revive (see below) — dead on arrival, which made
     its first two iterations look ineffective and sent the investigation
     down false paths ("maybe the pause duration matters").
   Fix: advancing reported time IS the steadiness signal (a genuine refill
   freezes the clock and stops the counter by itself). No buffering resets,
   no `isBuffering` conditions on this path. Commit `19ac086`.

2. **On-device diagnostics were structurally blind.**
   - VLCKit drops ALL libvlc internal messages unless a logger is attached
     to `VLCLibrary.loggers`. Nobody had ever seen what the audio output
     actually did on a failing device. `VLCLibraryLogBridge` (in
     `VLCKitEngine.swift`) now forwards audio/clock/ES messages plus all
     warnings/errors into the unified log, category `libvlc`, at `.notice`+
     so they persist into `log collect` archives and sysdiagnoses. Never
     remove it while any audio bug is open. `vlcVerboseLogging` user
     default = full firehose.
   - App-side state-change logging used `.debug`, which OSLog does NOT
     persist — invisible in collected archives. Diagnostic breadcrumbs must
     be `.notice` or higher.
   Capture procedure: reproduce on device, then
   `sudo log collect --device --last 30m --output dusk.logarchive` and read
   with `/usr/bin/log show --archive … --info --predicate 'subsystem ==
   "com.dusk-player.app"'` (note: zsh has a `log` builtin — use the full
   path).

3. **Stale VLCKit embeds shipped to devices.**
   Xcode's framework-embed step silently reused cached pre-patch VLCKit
   binaries after the vendored frameworks were replaced in-place, so device
   builds ran old libvlc while the repo contained the patched one. Guards
   now exist: `scripts/verify_embedded_vlckit.sh` fails the build on a stale
   embed, and Playback Info shows a runtime "VLCKit Build" row
   (`VLCKitEngine.vendoredVLCKitAudit`) plus a "VLC Audio Module" row (the
   `avsamplebuffer` A/B toggle bypasses every audiounit patch). Check these
   rows FIRST when a device misbehaves.

## The actual silent state and its cure

The failing state renders silence while consuming buffers and reporting
success — libvlc-side recovery (vendored patches 0015/0016) cannot engage
because nothing fails, and the app cannot detect it because VLCKit exposes
no rendered-PCM signal. Its exact libvlc-level identity is still not pinned
down (candidates: render callback dying without any notification, or PCM
zeroing between decoder and hardware); what IS proven on device:

- the state occurs right after audio-output bring-up (media open) and after
  seek-flush churn;
- **a pause→resume cycle always cures it** (AudioOutputUnitStop → session
  reactivation → AudioOutputUnitStart → render unlatch → fresh timing
  report re-syncing the master clock);
- once cured, playback stays healthy until the next disturbance.

The mitigation is the engine's **settle audio revive**
(`beginAudioRevive` and the `AudioRevivePhase` machine in
`VLCKitEngine`): an automated replica of the manual cure, run CLOSED-LOOP —
pause issued → wait for libvlc's `.paused` confirmation → hold (1.2 s on
initial warmup via `vlcAudioWarmupReviveGapMs`, 100 ms on seek revives via
`vlcAudioReviveGapMs`) → play issued → wait
for the `.playing` confirmation, with bounded re-play enforcement for
stray late pauses and failsafe timers whose expiry actions are safe in
every ordering. An earlier open-loop version (pause → sleep → play)
provably lost the ordering race on slow connections and stranded the
player paused — never reintroduce wall-clock sequencing here. One-shot
per disturbance (open, stall recovery, seek burst), rate-limited, arm
survives until a revive actually starts. TRIGGER TIMING IS
EFFECTIVENESS-CRITICAL, separately from sequencing correctness: the
initial-warmup cure only works once playback has rendered for ~1 s (≥4
advancing ticks) with a 1.2 s hold — the silent state forms during the
first second, and firing at the first tick or the `.playing` event cured
seeks but provably NOT starts (device-tested 2026-07-06, multiple builds).
Seek revives fire at the `.playing` transition after a refill or the first
tick, with a 100 ms hold. On initial bring-up the warmup is masked as
`.loading` (and the center play/pause button hidden) so the UI only ever
sees loading → playing-with-audio. iOS/iPadOS only. If the
root cause is ever fixed at the libvlc level, the revive can become a
dormant safety net — do not remove it based on theory alone; it is the only
proven cure.

## False leads (do not re-chase these without new evidence)

- Interruption latches, session-activation failures, resume fall-throughs,
  start-deferral pathologies (vendored patches 0015/0016 cover them; the
  logged failing sessions showed none firing — deferral was a healthy
  ~80 ms).
- Audio-session mode/policy, spatial audio, mix modes, route churn — the
  failing sessions had zero route/interruption events.
- `:start-time` as a resume mechanism — it shifts libvlc's whole reported
  timeline (sub-clip semantics) and would corrupt Plex progress reporting.
  The resume seek is issued right after `play()` instead (queued before the
  audio output exists), with a fallback on the first `.playing` state.
- "Any post-bring-up moment is equally good for the cure" — false. The
  100 ms gap and early triggers cure SEEK silence but not START silence;
  the start cure needs ~1 s of rendered progress before the pause and a
  1.2 s hold. Do not re-tighten the warmup revive without device evidence;
  the loading mask makes its latency invisible anyway.

## Also fixed along the way (keep these)

- One seek command per seek (`applySeek` sets only `time`; the old
  `position`+`time` pair doubled every flush).
- Seek-verification retries are skipped while buffering (an accepted far
  seek that is refilling must not be re-seeked — that multiplied the flush
  storm that killed audio on far double-taps).
- VLC network/file caching 8000 ms → 1500 ms (`PlaybackBufferPolicy`):
  libvlc caching is the input pts_delay and scales every clock window; 8 s
  was far outside field-proven territory (VLC-iOS ships 999 ms).
- The coordinator logs the audio preselect decision with a per-stream
  summary; `:audio-track` preselect misses are diagnosable from logs now.
