#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build"
IOS_FRAMEWORK_DIR="${ROOT_DIR}/Frameworks/MobileVLCKit.xcframework"
TVOS_FRAMEWORK_DIR="${ROOT_DIR}/Frameworks/TVVLCKit.xcframework"
LICENSE_PATH="${ROOT_DIR}/Frameworks/VLCKit-LICENSE.txt"
VERSION_PATH="${ROOT_DIR}/Frameworks/VLCKit-VERSION.txt"
EXTRACT_DIR="${BUILD_DIR}/vlckit-prebuilt"

# Installs the pinned VLCKit binaries into Frameworks/. The xcframeworks are not
# committed to git: CI fetches them via ci_scripts/ci_post_clone.sh, and this
# script must be run once locally after cloning (and to refresh the pinned
# version). It is idempotent — a no-op when the expected build is already in
# place.
#
# Preferred: Dusk's OWN build of the stable MobileVLCKit/TVVLCKit line
# (VLCKit 3.7.3, libvlc 3.0.23) with the patches in ci_scripts/vlc-patches/:
# ffmpeg's TrueHD/MLP decoders re-enabled and tvOS multichannel output fixed.
# ci_scripts/build_vlckit.sh builds the archives from source (arm64 device +
# arm64 simulator slices only). They are assets of the release
# vlckit-<version> in the PRIVATE repo marvinvr/dusk-vlckit, downloaded with
# `gh release download` (needs a gh login or GH_TOKEN with access) and pinned
# here by name and checksum. See docs/development-workflow.md → "VLCKit build".
# Shipping the TrueHD decoder is a deliberate licensing decision; see
# docs/playback.md → "Dolby TrueHD decoding".
#
# Fallback without access to that repo: VideoLAN's stock prebuilt 3.7.3
# (public CocoaPods archives, thinned to arm64). The app works with it; it
# reads the build stamp at runtime and sends TrueHD through Plex.
# DUSK_VLCKIT_REQUIRE_DUSK=1 turns the fallback into an error (release builds:
# scripts/testflight.sh sets it).
VLCKIT_VERSION="3.7.3-dusk2"
DUSK_RELEASE_REPO="marvinvr/dusk-vlckit"
DUSK_RELEASE_TAG="vlckit-${VLCKIT_VERSION}"
IOS_ARCHIVE="MobileVLCKit-${VLCKIT_VERSION}.tar.xz"
IOS_ARCHIVE_SHA256="e4a1114d51ee1512c8c7f4357f665b86aeca45ed0ec9620fb351564665c14f9d"
TVOS_ARCHIVE="TVVLCKit-${VLCKIT_VERSION}.tar.xz"
TVOS_ARCHIVE_SHA256="5587f4898c70aca3fc3529849188e1a5a6b3d49938582ecfc584983c8faf9ba0"

STOCK_VERSION="3.7.3-stock"
STOCK_DOWNLOAD_BASE_URL="https://download.videolan.org/pub/cocoapods/prod"
STOCK_IOS_ARCHIVE="MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz"
STOCK_IOS_ARCHIVE_SHA256="0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9"
STOCK_TVOS_ARCHIVE="TVVLCKit-3.7.3-319ed2c0-79128878.tar.xz"
STOCK_TVOS_ARCHIVE_SHA256="b5f90c226ed54d9dc1c03901c60dc7749b74a53caace2c3047e4c0b7a063e46c"

# Marker file inside each installed xcframework: what this script installed.
INSTALLED_MARKER="vlckit-installed.txt"

# Optional: point at a directory that already holds the Dusk archives
# (matching names + checksums) to skip the download, e.g. build_vlckit.sh's
# output:  DUSK_VLCKIT_CACHE_DIR=.build/vlckit/out ci_scripts/install_vlckit.sh
CACHE_DIR="${DUSK_VLCKIT_CACHE_DIR:-}"

cleanup() {
    local exit_code=$?
    rm -rf "${EXTRACT_DIR}"
    rmdir "${BUILD_DIR}" >/dev/null 2>&1 || true
    exit "${exit_code}"
}

trap cleanup EXIT

# The build stamp build_vlckit.sh writes into a framework slice's Info.plist.
framework_build() {
    /usr/libexec/PlistBuddy -c "Print :DuskVLCKitBuild" "$1/Info.plist" 2>/dev/null || true
}

# Checks the installed binaries themselves, not Frameworks/VLCKit-VERSION.txt:
# that file is tracked in git, so it already names the new version right after
# a pull, while the git-ignored frameworks (and the copies scripts/testflight.sh
# takes from the checkout) can still be an older or stock build.
has_dusk_vlckit() {
    [ "$(framework_build "${IOS_FRAMEWORK_DIR}/ios-arm64/MobileVLCKit.framework")" = "${VLCKIT_VERSION}" ] &&
    [ "$(framework_build "${IOS_FRAMEWORK_DIR}/ios-arm64-simulator/MobileVLCKit.framework")" = "${VLCKIT_VERSION}" ] &&
    [ "$(framework_build "${TVOS_FRAMEWORK_DIR}/tvos-arm64/TVVLCKit.framework")" = "${VLCKIT_VERSION}" ] &&
    [ "$(framework_build "${TVOS_FRAMEWORK_DIR}/tvos-arm64-simulator/TVVLCKit.framework")" = "${VLCKIT_VERSION}" ]
}

has_stock_vlckit() {
    [ -d "${IOS_FRAMEWORK_DIR}/ios-arm64" ] &&
    [ -d "${IOS_FRAMEWORK_DIR}/ios-arm64-simulator" ] &&
    [ -d "${TVOS_FRAMEWORK_DIR}/tvos-arm64" ] &&
    [ -d "${TVOS_FRAMEWORK_DIR}/tvos-arm64-simulator" ] &&
    [ "$(cat "${IOS_FRAMEWORK_DIR}/${INSTALLED_MARKER}" 2>/dev/null)" = "${STOCK_VERSION}" ] &&
    [ "$(cat "${TVOS_FRAMEWORK_DIR}/${INSTALLED_MARKER}" 2>/dev/null)" = "${STOCK_VERSION}" ]
}

verify_sha256() {
    local file_path="$1"
    local expected="$2"
    local actual

    actual="$(shasum -a 256 "${file_path}" | awk '{print $1}')"
    if [ "${actual}" != "${expected}" ]; then
        echo "ERROR: checksum mismatch for ${file_path}" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        return 1
    fi
}

# Downloads one stock archive from VideoLAN's CDN.
fetch_stock_archive() {
    local archive_name="$1"
    local expected_sha="$2"
    local destination="${EXTRACT_DIR}/${archive_name}"

    # Transient CDN/TLS resets are common for archives this size, and curl's
    # plain --retry does not cover CURLE_SSL_CONNECT_ERROR. Retry every
    # transfer failure and resume the partial archive.
    curl \
        --fail \
        --location \
        --retry 8 \
        --retry-all-errors \
        --retry-delay 3 \
        --continue-at - \
        --output "${destination}" \
        "${STOCK_DOWNLOAD_BASE_URL}/${archive_name}"
    verify_sha256 "${destination}" "${expected_sha}"
}

# Whether this machine can read the private release (gh installed, logged in
# or GH_TOKEN set, with access to the repo).
can_read_dusk_release() {
    command -v gh >/dev/null 2>&1 &&
    gh release view "${DUSK_RELEASE_TAG}" --repo "${DUSK_RELEASE_REPO}" >/dev/null 2>&1
}

# Copies one Dusk archive from the cache dir or downloads it from the private
# release. A checksum mismatch is always fatal, never a reason to fall back.
fetch_dusk_archive() {
    local archive_name="$1"
    local expected_sha="$2"
    local destination="${EXTRACT_DIR}/${archive_name}"
    local attempt

    if [ -n "${CACHE_DIR}" ] && [ -f "${CACHE_DIR}/${archive_name}" ]; then
        cp "${CACHE_DIR}/${archive_name}" "${destination}"
    else
        for attempt in 1 2 3 4; do
            if gh release download "${DUSK_RELEASE_TAG}" \
                --repo "${DUSK_RELEASE_REPO}" \
                --pattern "${archive_name}" \
                --dir "${EXTRACT_DIR}" \
                --clobber; then
                break
            fi
            if [ "${attempt}" = 4 ]; then
                echo "ERROR: could not download ${archive_name} from ${DUSK_RELEASE_REPO}." >&2
                return 1
            fi
            sleep 3
        done
    fi
    verify_sha256 "${destination}" "${expected_sha}"
}

has_cached_dusk_archives() {
    [ -n "${CACHE_DIR}" ] &&
    [ -f "${CACHE_DIR}/${IOS_ARCHIVE}" ] &&
    [ -f "${CACHE_DIR}/${TVOS_ARCHIVE}" ]
}

# Rewrites the xcframework Info.plist entry for a thinned slice. The
# AvailableLibraries array order is not stable across builds, so locate the
# entry by its LibraryIdentifier instead of assuming an index.
patch_thinned_slice_plist() {
    local plist_path="$1"
    local fat_identifier="$2"
    local thin_identifier="$3"
    local index=0

    while true; do
        local identifier
        identifier="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:${index}:LibraryIdentifier" "${plist_path}" 2>/dev/null)" || break
        if [ "${identifier}" = "${fat_identifier}" ]; then
            plutil -replace "AvailableLibraries.${index}.LibraryIdentifier" -string "${thin_identifier}" "${plist_path}"
            plutil -replace "AvailableLibraries.${index}.SupportedArchitectures" -json '["arm64"]' "${plist_path}"
            return 0
        fi
        index=$((index + 1))
    done

    echo "ERROR: ${fat_identifier} not found in ${plist_path}" >&2
    return 1
}
# Thins one slice of an installed xcframework to arm64 and renames its
# directory + Info.plist entry. No-ops when the fat slice is absent (e.g. a
# slice that is already arm64-only keeps its original identifier).
thin_slice() {
    local xcframework_dir="$1"
    local framework_name="$2"
    local fat_identifier="$3"
    local thin_identifier="$4"
    local fat_dir="${xcframework_dir}/${fat_identifier}"
    local thin_dir="${xcframework_dir}/${thin_identifier}"
    local framework_binary="${thin_dir}/${framework_name}.framework/${framework_name}"
    local thin_binary

    [ -d "${fat_dir}" ] || return 0

    mv "${fat_dir}" "${thin_dir}"

    thin_binary="$(mktemp -t dusk-vlckit.XXXXXX)"
    xcrun lipo "${framework_binary}" -thin arm64 -output "${thin_binary}"
    mv "${thin_binary}" "${framework_binary}"
    chmod 755 "${framework_binary}"

    patch_thinned_slice_plist "${xcframework_dir}/Info.plist" \
        "${fat_identifier}" "${thin_identifier}"

    codesign --force --sign - --timestamp=none "${thin_dir}/${framework_name}.framework" >/dev/null 2>&1
}

remove_debug_symbol_paths() {
    local framework_dir="$1"
    local plist_path="${framework_dir}/Info.plist"
    local index=0

    while /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:${index}" "${plist_path}" >/dev/null 2>&1; do
        /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:${index}:DebugSymbolsPath" "${plist_path}" >/dev/null 2>&1 || true
        index=$((index + 1))
    done
}

install_framework() {
    local source_dir="$1"
    local destination_dir="$2"

    rm -rf "${destination_dir}"
    cp -R "${source_dir}" "${destination_dir}"
    find "${destination_dir}" -type d -name dSYMs -prune -exec rm -rf {} +
    remove_debug_symbol_paths "${destination_dir}"
}

install_dusk_vlckit() {
    echo "Installing Dusk's MobileVLCKit/TVVLCKit ${VLCKIT_VERSION}..."
    fetch_dusk_archive "${IOS_ARCHIVE}" "${IOS_ARCHIVE_SHA256}"
    fetch_dusk_archive "${TVOS_ARCHIVE}" "${TVOS_ARCHIVE_SHA256}"

    tar -xf "${EXTRACT_DIR}/${IOS_ARCHIVE}" -C "${EXTRACT_DIR}"
    tar -xf "${EXTRACT_DIR}/${TVOS_ARCHIVE}" -C "${EXTRACT_DIR}"

    install_framework "${EXTRACT_DIR}/MobileVLCKit-binary/MobileVLCKit.xcframework" "${IOS_FRAMEWORK_DIR}"
    install_framework "${EXTRACT_DIR}/TVVLCKit-binary/TVVLCKit.xcframework" "${TVOS_FRAMEWORK_DIR}"

    if ! has_dusk_vlckit; then
        echo "ERROR: the installed frameworks are not stamped as Dusk VLCKit ${VLCKIT_VERSION}." >&2
        exit 1
    fi
    printf '%s\n' "${VLCKIT_VERSION}" > "${IOS_FRAMEWORK_DIR}/${INSTALLED_MARKER}"
    printf '%s\n' "${VLCKIT_VERSION}" > "${TVOS_FRAMEWORK_DIR}/${INSTALLED_MARKER}"

    cp "${EXTRACT_DIR}/MobileVLCKit-binary/COPYING.txt" "${LICENSE_PATH}"
    printf '%s\n' "${VLCKIT_VERSION}" > "${VERSION_PATH}"

    echo "Dusk MobileVLCKit installed at ${IOS_FRAMEWORK_DIR}."
    echo "Dusk TVVLCKit installed at ${TVOS_FRAMEWORK_DIR}."
}

# VideoLAN's stock build. Leaves the tracked VLCKit-VERSION.txt alone (it
# names the Dusk build the repo pins) and marks the install instead.
install_stock_vlckit() {
    echo "Installing VideoLAN's stock MobileVLCKit/TVVLCKit 3.7.3..."
    fetch_stock_archive "${STOCK_IOS_ARCHIVE}" "${STOCK_IOS_ARCHIVE_SHA256}"
    fetch_stock_archive "${STOCK_TVOS_ARCHIVE}" "${STOCK_TVOS_ARCHIVE_SHA256}"

    tar -xf "${EXTRACT_DIR}/${STOCK_IOS_ARCHIVE}" -C "${EXTRACT_DIR}"
    tar -xf "${EXTRACT_DIR}/${STOCK_TVOS_ARCHIVE}" -C "${EXTRACT_DIR}"

    install_framework "${EXTRACT_DIR}/MobileVLCKit-binary/MobileVLCKit.xcframework" "${IOS_FRAMEWORK_DIR}"
    thin_slice "${IOS_FRAMEWORK_DIR}" "MobileVLCKit" "ios-arm64_armv7_armv7s" "ios-arm64"
    thin_slice "${IOS_FRAMEWORK_DIR}" "MobileVLCKit" "ios-arm64_i386_x86_64-simulator" "ios-arm64-simulator"

    install_framework "${EXTRACT_DIR}/TVVLCKit-binary/TVVLCKit.xcframework" "${TVOS_FRAMEWORK_DIR}"
    thin_slice "${TVOS_FRAMEWORK_DIR}" "TVVLCKit" "tvos-arm64_x86_64-simulator" "tvos-arm64-simulator"

    printf '%s\n' "${STOCK_VERSION}" > "${IOS_FRAMEWORK_DIR}/${INSTALLED_MARKER}"
    printf '%s\n' "${STOCK_VERSION}" > "${TVOS_FRAMEWORK_DIR}/${INSTALLED_MARKER}"
    cp "${EXTRACT_DIR}/MobileVLCKit-binary/COPYING.txt" "${LICENSE_PATH}"

    echo "Stock MobileVLCKit installed at ${IOS_FRAMEWORK_DIR}."
    echo "Stock TVVLCKit installed at ${TVOS_FRAMEWORK_DIR}."
}

if has_dusk_vlckit; then
    echo "Dusk MobileVLCKit/TVVLCKit ${VLCKIT_VERSION} frameworks already present."
    exit 0
fi

rm -rf "${EXTRACT_DIR}"
mkdir -p "${ROOT_DIR}/Frameworks" "${EXTRACT_DIR}"

if has_cached_dusk_archives || can_read_dusk_release; then
    install_dusk_vlckit
    exit 0
fi

if [ "${DUSK_VLCKIT_REQUIRE_DUSK:-0}" = "1" ]; then
    echo "ERROR: Dusk VLCKit ${VLCKIT_VERSION} is required but ${DUSK_RELEASE_REPO} is not readable (gh auth status / GH_TOKEN)." >&2
    exit 1
fi

echo "warning: no access to ${DUSK_RELEASE_REPO} (gh missing, not logged in, or no permission)."
echo "warning: falling back to VideoLAN's stock VLCKit 3.7.3 — TrueHD will play through Plex."

if has_stock_vlckit; then
    echo "Stock MobileVLCKit/TVVLCKit 3.7.3 frameworks already present."
    exit 0
fi

install_stock_vlckit
