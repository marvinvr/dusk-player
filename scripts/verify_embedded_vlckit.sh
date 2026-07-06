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
# embed step performs) between the embedded binary and the repo copy.
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
