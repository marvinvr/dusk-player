#!/bin/bash
set -euo pipefail

# Builds Dusk's own MobileVLCKit/TVVLCKit 3.x from source: VideoLAN's VLCKit
# 3.7.3 (libvlc 3.0.23) plus the Dusk patches in this directory, arm64 device
# and arm64 simulator slices. MANUAL maintenance script — CI never runs it; CI
# downloads the published archives through install_vlckit.sh.
#
#   ci_scripts/build_vlckit.sh [ios|tvos|all]     (default: all)
#
# Why a custom build: stock VLCKit disables ffmpeg's mlp/truehd decoders (Dolby
# licensing), so TrueHD had to be transcoded by Plex to E-AC-3 5.1. The Dusk
# patches restore TrueHD/MLP decoding (lossless PCM, up to 7.1) and fix tvOS
# multichannel output. Shipping the TrueHD decoder is a deliberate licensing
# decision — read "Dolby TrueHD decoding" in docs/playback.md first.
#
# Patches:
#   vlckit-patches/*.patch  applied to the VLCKit checkout (build script)
#   vlc-patches/*.patch     copied into VLCKit's libvlc/patches/, which
#                           buildMobileVLCKit.sh git-am's onto vlc 3.0.x after
#                           VideoLAN's own series (numbered 0100+ to sort last)
#
# Output (DUSK_VLCKIT_OUT_DIR, default .build/vlckit/out):
#   MobileVLCKit-<version>.tar.xz / TVVLCKit-<version>.tar.xz, laid out like
#   VideoLAN's CocoaPods archives (<Name>-binary/<Name>.xcframework +
#   COPYING.txt), plus their SHA-256 sums. Publish them as release assets
#   (tag vlckit-<version>) in the PRIVATE repo marvinvr/dusk-vlckit and pin
#   name + checksum in install_vlckit.sh. Never publish them publicly.
#   To install a fresh build locally without publishing:
#     DUSK_VLCKIT_CACHE_DIR=.build/vlckit/out ci_scripts/install_vlckit.sh
#
# The iOS and tvOS builds use separate source trees, so they can run in
# parallel (`build_vlckit.sh ios & build_vlckit.sh tvos`). A full build takes
# roughly an hour per platform on an M-series Mac and needs ~25 GB of disk.
# Trees are reused between runs; DUSK_VLCKIT_CLEAN=1 starts from scratch.
# DUSK_VLCKIT_PACKAGE_ONLY=1 re-verifies and re-packages a finished build.
#
# Bump DUSK_VLCKIT_BUILD whenever the patches change, so install_vlckit.sh
# (which compares Frameworks/VLCKit-VERSION.txt) replaces old installs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VLCKIT_REPO_URL="https://code.videolan.org/videolan/VLCKit.git"
VLCKIT_TAG="3.7.3"
VLCKIT_COMMIT="319ed2c0724e3d4c4d34889a62fef1ae269491bc"
DUSK_VLCKIT_BUILD="dusk3"
VERSION="${VLCKIT_TAG}-${DUSK_VLCKIT_BUILD}"

WORK_DIR="${DUSK_VLCKIT_WORK_DIR:-${ROOT_DIR}/.build/vlckit}"
OUT_DIR="${DUSK_VLCKIT_OUT_DIR:-${WORK_DIR}/out}"
VLCKIT_PATCH_DIR="${ROOT_DIR}/ci_scripts/vlckit-patches"
VLC_PATCH_DIR="${ROOT_DIR}/ci_scripts/vlc-patches"

GIT_IDENTITY=(-c user.name="Dusk VLCKit Build" -c user.email="vlckit-build@dusk.invalid")

log() {
    printf '[build_vlckit %s] %s\n' "$(date +%H:%M:%S)" "$*"
}

prepare_source() {
    local src="$1"

    if [ "${DUSK_VLCKIT_CLEAN:-0}" = "1" ] && [ -d "${src}" ]; then
        log "Removing ${src}"
        rm -rf "${src:?}"
    fi

    if [ ! -d "${src}/.git" ]; then
        git clone --quiet "${VLCKIT_REPO_URL}" "${src}"
    fi

    git -C "${src}" fetch --quiet --tags origin
    git -C "${src}" checkout --quiet --force -B dusk-build "${VLCKIT_COMMIT}"
    if [ "$(git -C "${src}" rev-parse "${VLCKIT_TAG}^{commit}")" != "${VLCKIT_COMMIT}" ]; then
        echo "error: VLCKit tag ${VLCKIT_TAG} no longer points at ${VLCKIT_COMMIT}." >&2
        exit 1
    fi
    # Reset tracked files but keep libvlc/vlc (git-ignored): its built
    # contribs make a rebuild incremental. buildMobileVLCKit.sh resets that
    # checkout to its pinned hash and re-applies every patch on each run.
    git -C "${src}" reset --quiet --hard
    git -C "${src}" clean --quiet -fd -- Resources build

    git -C "${src}" "${GIT_IDENTITY[@]}" am --quiet "${VLCKIT_PATCH_DIR}"/*.patch
    cp "${VLC_PATCH_DIR}"/*.patch "${src}/libvlc/patches/"

    # buildMobileVLCKit.sh only clones vlc when it is missing; an existing
    # checkout must have no git-am session left from an interrupted run.
    if [ -d "${src}/libvlc/vlc/.git/rebase-apply" ]; then
        git -C "${src}/libvlc/vlc" am --abort || true
    fi
}

# Fails unless ffmpeg's TrueHD/MLP decoders made it into the contrib build.
verify_truehd_contrib() {
    local src="$1"
    local osstyle="$2"
    local platform libavcodec symbols decoder

    for platform in OS Simulator; do
        libavcodec="${src}/libvlc/vlc/contrib/${osstyle}${platform}-aarch64-apple-darwin-aarch64/lib/libavcodec.a"
        # Captured first: `nm | grep -q` fails under pipefail once grep exits
        # early and nm dies of SIGPIPE.
        symbols="$(nm -g "${libavcodec}" 2>/dev/null || true)"
        for decoder in ff_truehd_decoder ff_mlp_decoder; do
            if ! grep -Eq " [DRS] _${decoder}$" <<< "${symbols}"; then
                echo "error: ${libavcodec} has no ${decoder} — the TrueHD patch did not apply." >&2
                exit 1
            fi
        done
    done
    log "TrueHD/MLP decoders present in the ${osstyle} contribs."
}

# Fails when a slice weak-links a libSystem function that older OS versions do
# not have. Xcode's SDK can declare functions newer than VLCKit's deployment
# target (pipe2 is iOS/tvOS/macOS 27+); configure then picks them up, the
# linker weak-imports them, and libvlc calls NULL on older OS versions (dusk1
# crashed on every network open on tvOS 26 and macOS 26). The allowed names are
# the ones VideoLAN's own stock builds carry, which are always resolvable.
verify_no_new_libsystem_imports() {
    local xcframework="$1"
    local name="$2"
    local slice weak

    for slice in "${xcframework}"/*/"${name}.framework"; do
        weak="$(nm -m "${slice}/${name}" 2>/dev/null |
            grep -E '\(undefined\) weak external .*\(from libSystem\)' |
            grep -Ev ' (___darwin_check_fd_set_overflow|__availability_version_check|_os_unfair_lock_lock|_os_unfair_lock_unlock) ' || true)"
        if [ -n "${weak}" ]; then
            echo "error: ${slice} weak-links libSystem functions that older OS versions lack:" >&2
            echo "${weak}" >&2
            echo "Patch libvlc (ci_scripts/vlc-patches) so it does not use them." >&2
            exit 1
        fi
    done
    log "${name}: no weak-linked libSystem functions."
}

# Marks every slice so the app can tell this build from a stock VLCKit at
# runtime (VLCKitEngine reads DuskVLCKitTrueHD before treating TrueHD as
# decodable).
stamp_framework() {
    local xcframework="$1"
    local name="$2"
    local slice plist

    for slice in "${xcframework}"/*/"${name}.framework"; do
        plist="${slice}/Info.plist"
        /usr/libexec/PlistBuddy -c "Delete :DuskVLCKitBuild" "${plist}" >/dev/null 2>&1 || true
        /usr/libexec/PlistBuddy -c "Delete :DuskVLCKitTrueHD" "${plist}" >/dev/null 2>&1 || true
        /usr/libexec/PlistBuddy -c "Add :DuskVLCKitBuild string ${VERSION}" "${plist}"
        /usr/libexec/PlistBuddy -c "Add :DuskVLCKitTrueHD bool true" "${plist}"
        codesign --force --sign - --timestamp=none "${slice}" >/dev/null 2>&1
    done
}

package_platform() {
    local src="$1"
    local name="$2"
    local device_slice="$3"
    local simulator_slice="$4"
    local built="${src}/build/${name}.xcframework"
    local staging="${OUT_DIR}/${name}-binary"
    local archive="${OUT_DIR}/${name}-${VERSION}.tar.xz"

    for slice in "${device_slice}" "${simulator_slice}"; do
        if [ ! -d "${built}/${slice}/${name}.framework" ]; then
            echo "error: ${built} has no ${slice} slice." >&2
            exit 1
        fi
    done

    rm -rf "${staging}"
    mkdir -p "${staging}"
    cp -R "${built}" "${staging}/"
    find "${staging}" -type d -name dSYMs -prune -exec rm -rf {} +
    verify_no_new_libsystem_imports "${staging}/${name}.xcframework" "${name}"
    stamp_framework "${staging}/${name}.xcframework" "${name}"
    cp "${src}/COPYING" "${staging}/COPYING.txt"

    rm -f "${archive}"
    tar -C "${OUT_DIR}" -cJf "${archive}" "${name}-binary"
    rm -rf "${staging}"
    (cd "${OUT_DIR}" && shasum -a 256 "$(basename "${archive}")" > "$(basename "${archive}").sha256")
    log "Packaged $(cat "${archive}.sha256")"
}

build_platform() {
    local platform="$1"
    local src="${WORK_DIR}/${platform}"
    local log_file="${WORK_DIR}/${platform}.log"
    local flags=(-a aarch64)
    local name="MobileVLCKit"
    local osstyle="iPhone"
    local device_slice="ios-arm64"
    local simulator_slice="ios-arm64-simulator"

    if [ "${platform}" = "tvos" ]; then
        flags+=(-t)
        name="TVVLCKit"
        osstyle="AppleTV"
        device_slice="tvos-arm64"
        simulator_slice="tvos-arm64-simulator"
    fi

    mkdir -p "${WORK_DIR}" "${OUT_DIR}"
    if [ "${DUSK_VLCKIT_PACKAGE_ONLY:-0}" = "1" ]; then
        log "Packaging the existing ${name} build in ${src}"
        verify_truehd_contrib "${src}" "${osstyle}"
        package_platform "${src}" "${name}" "${device_slice}" "${simulator_slice}"
        return
    fi

    log "Preparing ${name} ${VERSION} in ${src}"
    prepare_source "${src}"

    log "Building ${name} (log: ${log_file})"
    # The VLCKit script resets PATH to its own toolchain; it only needs a
    # clean environment and the git identity for its git-am step.
    (
        cd "${src}"
        export GIT_AUTHOR_NAME="Dusk VLCKit Build" GIT_AUTHOR_EMAIL="vlckit-build@dusk.invalid"
        export GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}" GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
        ./buildMobileVLCKit.sh -v "${flags[@]}"
    ) > "${log_file}" 2>&1 || {
        echo "error: ${name} build failed; last lines of ${log_file}:" >&2
        tail -40 "${log_file}" >&2
        exit 1
    }

    verify_truehd_contrib "${src}" "${osstyle}"
    package_platform "${src}" "${name}" "${device_slice}" "${simulator_slice}"
}

case "${1:-all}" in
    ios) build_platform ios ;;
    tvos) build_platform tvos ;;
    all)
        build_platform ios
        build_platform tvos
        ;;
    *)
        echo "usage: $0 [ios|tvos|all]" >&2
        exit 2
        ;;
esac

log "Done. Archives in ${OUT_DIR}."
