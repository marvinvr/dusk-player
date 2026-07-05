#!/bin/bash
# Fails the build when the VLCKit embedded into the app product is missing
# the audio-silence recovery patches (vlc-patches 0015/0016) that the
# checked-in Frameworks/ binaries contain.
#
# Why this exists: Xcode's framework-embed step can silently keep a stale
# cached copy when a checked-in framework binary is replaced in-place (the
# vendored VLCKit updates do exactly that). This has shipped device builds
# with pre-patch VLCKit while the repo contained the patched one, which
# makes every audio fix look ineffective and costs hours of phantom
# debugging. A hard build failure with a clear message is cheaper.
#
# The marker string is a log message added by vlc-patch 0015
# (ci_scripts/vlc-patches/0015-...). If the patch series is ever rebuilt
# without it, update the marker here and in VLCKitEngine.vendoredVLCKitAudit.
set -euo pipefail

MARKER="clamping excessive audio start deferral"
FRAMEWORK_BINARY="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/VLCKit.framework/VLCKit"

if [ ! -f "${FRAMEWORK_BINARY}" ]; then
    echo "warning: VLCKit binary not found at ${FRAMEWORK_BINARY}; skipping staleness check."
    exit 0
fi

if LC_ALL=C grep -aq "${MARKER}" "${FRAMEWORK_BINARY}"; then
    echo "note: Embedded VLCKit contains the 0015/0016 audio recovery patches."
    exit 0
fi

echo "error: The VLCKit embedded in this build is STALE — it is missing the audio-silence recovery patches (vlc-patches 0015/0016) that Frameworks/ contains. Xcode reused an old cached copy. Delete DerivedData (or run a clean build) and build again."
exit 1
