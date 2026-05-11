#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build"
IOS_FRAMEWORK_DIR="${ROOT_DIR}/Frameworks/VLCKit.xcframework"
TVOS_FRAMEWORK_DIR="${ROOT_DIR}/Frameworks/VLCKit-tvOS.xcframework"
LICENSE_PATH="${ROOT_DIR}/Frameworks/VLCKit-LICENSE.txt"
VERSION_PATH="${ROOT_DIR}/Frameworks/VLCKit-VERSION.txt"
SOURCE_DIR="${BUILD_DIR}/vlckit-src"
VLCKIT_REPO_URL="https://code.videolan.org/videolan/VLCKit.git"
VLCKIT_REF="4.0.0a19"
TEMP_FILES=()

# Manual maintenance script for refreshing the vendored VLCKit binary.
# CI consumes the checked-in xcframework and should not run this script.

cleanup() {
    local exit_code=$?

    for temp_file in "${TEMP_FILES[@]:-}"; do
        [ -n "${temp_file}" ] && rm -f "${temp_file}"
    done

    rm -rf "${SOURCE_DIR}"
    rmdir "${BUILD_DIR}" >/dev/null 2>&1 || true

    exit "${exit_code}"
}

trap cleanup EXIT

make_temp_file() {
    local temp_file

    temp_file="$(mktemp -t dusk-vlckit.XXXXXX)"
    TEMP_FILES+=("${temp_file}")
    printf '%s\n' "${temp_file}"
}

has_expected_vlckit() {
    [ -d "${IOS_FRAMEWORK_DIR}" ] &&
    [ -d "${TVOS_FRAMEWORK_DIR}" ] &&
    [ -f "${VERSION_PATH}" ] &&
    [ "$(cat "${VERSION_PATH}")" = "${VLCKIT_REF}" ] &&
    [ -d "${IOS_FRAMEWORK_DIR}/ios-arm64-simulator" ] &&
    [ -d "${TVOS_FRAMEWORK_DIR}/tvos-arm64-simulator" ] &&
    find "${IOS_FRAMEWORK_DIR}" -path "*Headers/VLCDrawable.h" -print -quit | grep -q .
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

thin_ios_simulator_slice() {
    local simulator_dir="${IOS_FRAMEWORK_DIR}/ios-arm64_x86_64-simulator"
    local thin_simulator_dir="${IOS_FRAMEWORK_DIR}/ios-arm64-simulator"
    local simulator_framework="${thin_simulator_dir}/VLCKit.framework"
    local simulator_binary="${simulator_framework}/VLCKit"
    local thin_binary

    [ -d "${simulator_dir}" ] || return 0

    mv "${simulator_dir}" "${thin_simulator_dir}"

    thin_binary="$(make_temp_file)"
    xcrun lipo "${simulator_binary}" -thin arm64 -output "${thin_binary}"
    mv "${thin_binary}" "${simulator_binary}"
    chmod 755 "${simulator_binary}"

    plutil -replace 'AvailableLibraries.1.LibraryIdentifier' -string 'ios-arm64-simulator' "${IOS_FRAMEWORK_DIR}/Info.plist"
    plutil -replace 'AvailableLibraries.1.SupportedArchitectures' -json '["arm64"]' "${IOS_FRAMEWORK_DIR}/Info.plist"

    codesign --force --sign - --timestamp=none "${simulator_framework}" >/dev/null
}

thin_tvos_simulator_slice() {
    local simulator_dir="${TVOS_FRAMEWORK_DIR}/tvos-arm64_x86_64-simulator"
    local thin_simulator_dir="${TVOS_FRAMEWORK_DIR}/tvos-arm64-simulator"
    local simulator_framework="${thin_simulator_dir}/VLCKit.framework"
    local simulator_binary="${simulator_framework}/VLCKit"
    local thin_binary

    [ -d "${simulator_dir}" ] || return 0

    mv "${simulator_dir}" "${thin_simulator_dir}"

    thin_binary="$(make_temp_file)"
    xcrun lipo "${simulator_binary}" -thin arm64 -output "${thin_binary}"
    mv "${thin_binary}" "${simulator_binary}"
    chmod 755 "${simulator_binary}"

    plutil -replace 'AvailableLibraries.1.LibraryIdentifier' -string 'tvos-arm64-simulator' "${TVOS_FRAMEWORK_DIR}/Info.plist"
    plutil -replace 'AvailableLibraries.1.SupportedArchitectures' -json '["arm64"]' "${TVOS_FRAMEWORK_DIR}/Info.plist"

    codesign --force --sign - --timestamp=none "${simulator_framework}" >/dev/null
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
    echo "Pinned iOS and tvOS VLCKit frameworks already present."
    exit 0
fi

echo "Building VLCKit ${VLCKIT_REF} for iOS and tvOS from source..."

rm -rf "${SOURCE_DIR}"
mkdir -p "${ROOT_DIR}/Frameworks" "${BUILD_DIR}"

git clone --depth 1 --branch "${VLCKIT_REF}" "${VLCKIT_REPO_URL}" "${SOURCE_DIR}"

(
    cd "${SOURCE_DIR}"
    ./compileAndBuildVLCKit.sh -f -r
)

install_framework "${SOURCE_DIR}/build/iOS/VLCKit.xcframework" "${IOS_FRAMEWORK_DIR}"
thin_ios_simulator_slice

(
    cd "${SOURCE_DIR}"
    ./compileAndBuildVLCKit.sh -t -f -r
)

install_framework "${SOURCE_DIR}/build/tvOS/VLCKit.xcframework" "${TVOS_FRAMEWORK_DIR}"
thin_tvos_simulator_slice
cp "${SOURCE_DIR}/COPYING" "${LICENSE_PATH}"
printf '%s\n' "${VLCKIT_REF}" > "${VERSION_PATH}"

echo "Pinned iOS VLCKit installed at ${IOS_FRAMEWORK_DIR}."
echo "Pinned tvOS VLCKit installed at ${TVOS_FRAMEWORK_DIR}."
