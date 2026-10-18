#!/bin/bash
set -euo pipefail
probe_root="$(cd "$(dirname "$0")/.." && pwd)"
probe_build="$(mktemp -d /tmp/dusk-intro-probe.XXXXXX)"
trap 'rm -rf "$probe_build"' EXIT
xcrun swiftc -O -swift-version 6 \
  "$probe_root/Dusk/Sources/Playback/IntroOpeningFingerprint.swift" \
  "$probe_root/Dusk/Sources/Playback/IntroOpeningFingerprintMatcher.swift" \
  "$probe_root/Dusk/Sources/Playback/IntroOpeningObservation.swift" \
  "$probe_root/Dusk/Sources/Playback/IntroFrameHasher.swift" \
  "$probe_root/Dusk/Sources/Playback/IntroFingerprintStore.swift" \
  "$probe_root/scripts/IntroFingerprintProbe.swift" \
  -o "$probe_build/probe"
"$probe_build/probe" --fingerprints "$probe_root/scripts/fixtures/intro-calibration-fingerprints.json" "$@"
