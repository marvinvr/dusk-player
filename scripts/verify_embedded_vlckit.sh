#!/bin/bash
# Fails the build when the VLCKit binary embedded into the app product does
# not match the copy in Frameworks/ (fetched by ci_scripts/install_vlckit.sh).
#
# Why this exists: Xcode's framework-embed step can silently keep a stale
# cached copy when the framework binary in Frameworks/ is replaced in-place (a
# VLCKit version refresh does exactly that). This has shipped device builds
# with an old VLCKit while the repo contained a newer one, which makes every
# playback fix look ineffective and costs hours of phantom debugging. A hard
# build failure with a clear message is cheaper.
#
# The check compares Mach-O LC_UUIDs (stable across re-signing, which the
# embed step performs) between the embedded binary and the repo copy. It also
# rejects a VLCKit that weak-links libSystem functions newer than the OS
# versions Dusk supports (see below).
set -euo pipefail

FRAMEWORKS_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

case "${PLATFORM_NAME}" in
    iphoneos)
        FRAMEWORK_NAME="MobileVLCKit"
        REPO_SLICE="MobileVLCKit.xcframework/ios-arm64"
        ;;
    iphonesimulator)
        FRAMEWORK_NAME="MobileVLCKit"
        REPO_SLICE="MobileVLCKit.xcframework/ios-arm64-simulator"
        ;;
    appletvos)
        FRAMEWORK_NAME="TVVLCKit"
        REPO_SLICE="TVVLCKit.xcframework/tvos-arm64"
        ;;
    appletvsimulator)
        FRAMEWORK_NAME="TVVLCKit"
        REPO_SLICE="TVVLCKit.xcframework/tvos-arm64-simulator"
        ;;
    *)
        echo "warning: unknown platform ${PLATFORM_NAME}; skipping VLCKit staleness check."
        exit 0
        ;;
esac

EMBEDDED_BINARY="${FRAMEWORKS_DIR}/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
REPO_BINARY="${PROJECT_DIR}/Frameworks/${REPO_SLICE}/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"

if [ ! -f "${EMBEDDED_BINARY}" ]; then
    echo "warning: ${FRAMEWORK_NAME} binary not found at ${EMBEDDED_BINARY}; skipping staleness check."
    exit 0
fi

# A VLCKit built with a newer SDK than its deployment target can weak-link
# libSystem functions older OS versions lack: Dusk's 3.7.3-dusk1 build (Xcode
# 27 SDK) weak-linked pipe2, which only exists on iOS/tvOS/macOS 27, and
# crashed on the first network open on tvOS 26 and Mac (Designed for iPad) on
# macOS 26 (#27). The allowed names are the ones VideoLAN's stock builds carry.
new_weak_imports="$(xcrun nm -m "${EMBEDDED_BINARY}" 2>/dev/null |
    grep -E '\(undefined\) weak external .*\(from libSystem\)' |
    grep -Ev ' (___darwin_check_fd_set_overflow|__availability_version_check|_os_unfair_lock_lock|_os_unfair_lock_unlock) ' || true)"
if [ -n "${new_weak_imports}" ]; then
    echo "error: The embedded ${FRAMEWORK_NAME} weak-links libSystem functions that older OS versions do not have, so it crashes there:"
    echo "${new_weak_imports}"
    echo "error: Install the VLCKit this branch pins (Frameworks/VLCKit-VERSION.txt, ci_scripts/install_vlckit.sh)."
    exit 1
fi

if [ ! -f "${REPO_BINARY}" ]; then
    echo "warning: repo ${FRAMEWORK_NAME} binary not found at ${REPO_BINARY}; skipping staleness check."
    exit 0
fi

embedded_uuids="$(xcrun dwarfdump --uuid "${EMBEDDED_BINARY}" | awk '{print $2}' | sort)"
repo_uuids="$(xcrun dwarfdump --uuid "${REPO_BINARY}" | awk '{print $2}' | sort)"

if [ -z "${embedded_uuids}" ] || [ -z "${repo_uuids}" ]; then
    echo "warning: could not read Mach-O UUIDs; skipping staleness check."
    exit 0
fi

if comm -12 <(printf '%s\n' "${embedded_uuids}") <(printf '%s\n' "${repo_uuids}") | grep -q .; then
    echo "note: Embedded ${FRAMEWORK_NAME} matches the Frameworks/ copy."
    exit 0
fi

echo "error: The ${FRAMEWORK_NAME} embedded in this build is STALE — its Mach-O UUID does not match Frameworks/${REPO_SLICE}. Xcode reused an old cached copy. Delete DerivedData (or run a clean build) and build again."
exit 1
