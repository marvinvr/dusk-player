#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build"
IOS_FRAMEWORK_DIR="${ROOT_DIR}/Frameworks/MobileVLCKit.xcframework"
TVOS_FRAMEWORK_DIR="${ROOT_DIR}/Frameworks/TVVLCKit.xcframework"
LICENSE_PATH="${ROOT_DIR}/Frameworks/VLCKit-LICENSE.txt"
VERSION_PATH="${ROOT_DIR}/Frameworks/VLCKit-VERSION.txt"
EXTRACT_DIR="${BUILD_DIR}/vlckit-prebuilt"

# Manual maintenance script for refreshing the vendored VLCKit binaries.
# CI consumes the checked-in xcframeworks and should not run this script.
#
# Dusk vendors the STABLE MobileVLCKit/TVVLCKit line (libvlc 3.0), installed
# from VideoLAN's official prebuilt CocoaPods artifacts — not built from
# source and not patched. The previous 4.0.0aXX source-build setup (with the
# local libvlc patch series) lives in git history if it is ever needed again.
#
# Slices are thinned to arm64 (device and simulator): the app targets modern
# arm64-only OS versions and the armv7/i386/x86_64 slices only bloat the repo.
VLCKIT_VERSION="3.7.3"
DOWNLOAD_BASE_URL="https://download.videolan.org/pub/cocoapods/prod"
IOS_ARCHIVE="MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz"
IOS_ARCHIVE_SHA256="0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9"
TVOS_ARCHIVE="TVVLCKit-3.7.3-319ed2c0-79128878.tar.xz"
TVOS_ARCHIVE_SHA256="b5f90c226ed54d9dc1c03901c60dc7749b74a53caace2c3047e4c0b7a063e46c"

# Optional: point at a directory that already holds the downloaded archives
# (matching names + checksums) to skip the download.
CACHE_DIR="${DUSK_VLCKIT_CACHE_DIR:-}"

cleanup() {
    local exit_code=$?
    rm -rf "${EXTRACT_DIR}"
    rmdir "${BUILD_DIR}" >/dev/null 2>&1 || true
    exit "${exit_code}"
}

trap cleanup EXIT

has_expected_vlckit() {
    [ -d "${IOS_FRAMEWORK_DIR}/ios-arm64" ] &&
    [ -d "${IOS_FRAMEWORK_DIR}/ios-arm64-simulator" ] &&
    [ -d "${TVOS_FRAMEWORK_DIR}/tvos-arm64" ] &&
    [ -d "${TVOS_FRAMEWORK_DIR}/tvos-arm64-simulator" ] &&
    [ -f "${VERSION_PATH}" ] &&
    [ "$(cat "${VERSION_PATH}")" = "${VLCKIT_VERSION}" ]
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

fetch_archive() {
    local archive_name="$1"
    local expected_sha="$2"
    local destination="${EXTRACT_DIR}/${archive_name}"

    if [ -n "${CACHE_DIR}" ] && [ -f "${CACHE_DIR}/${archive_name}" ]; then
        cp "${CACHE_DIR}/${archive_name}" "${destination}"
    else
        curl -fL --retry 3 -o "${destination}" "${DOWNLOAD_BASE_URL}/${archive_name}"
    fi
    verify_sha256 "${destination}" "${expected_sha}"
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

    codesign --force --sign - --timestamp=none "${thin_dir}/${framework_name}.framework" >/dev/null
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

if has_expected_vlckit; then
    echo "Pinned MobileVLCKit/TVVLCKit ${VLCKIT_VERSION} frameworks already present."
    exit 0
fi

echo "Installing prebuilt MobileVLCKit/TVVLCKit ${VLCKIT_VERSION}..."

rm -rf "${EXTRACT_DIR}"
mkdir -p "${ROOT_DIR}/Frameworks" "${EXTRACT_DIR}"

fetch_archive "${IOS_ARCHIVE}" "${IOS_ARCHIVE_SHA256}"
fetch_archive "${TVOS_ARCHIVE}" "${TVOS_ARCHIVE_SHA256}"

tar -xf "${EXTRACT_DIR}/${IOS_ARCHIVE}" -C "${EXTRACT_DIR}"
tar -xf "${EXTRACT_DIR}/${TVOS_ARCHIVE}" -C "${EXTRACT_DIR}"

install_framework "${EXTRACT_DIR}/MobileVLCKit-binary/MobileVLCKit.xcframework" "${IOS_FRAMEWORK_DIR}"
thin_slice "${IOS_FRAMEWORK_DIR}" "MobileVLCKit" "ios-arm64_armv7_armv7s" "ios-arm64"
thin_slice "${IOS_FRAMEWORK_DIR}" "MobileVLCKit" "ios-arm64_i386_x86_64-simulator" "ios-arm64-simulator"

install_framework "${EXTRACT_DIR}/TVVLCKit-binary/TVVLCKit.xcframework" "${TVOS_FRAMEWORK_DIR}"
thin_slice "${TVOS_FRAMEWORK_DIR}" "TVVLCKit" "tvos-arm64_x86_64-simulator" "tvos-arm64-simulator"

cp "${EXTRACT_DIR}/MobileVLCKit-binary/COPYING.txt" "${LICENSE_PATH}"
printf '%s\n' "${VLCKIT_VERSION}" > "${VERSION_PATH}"

echo "Pinned MobileVLCKit installed at ${IOS_FRAMEWORK_DIR}."
echo "Pinned TVVLCKit installed at ${TVOS_FRAMEWORK_DIR}."
