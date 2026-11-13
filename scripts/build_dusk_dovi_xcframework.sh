#!/bin/bash
set -euo pipefail

# Builds Native/DuskDovi (Rust, over quietvoid's dolby_vision crate) into
# Frameworks/DuskDovi.xcframework: static libraries for iOS and tvOS, device
# and simulator, arm64 only (like VLCKit), plus one universal macOS slice
# (arm64 + x86_64, lipo'd, because an xcframework holds one library per platform). The xcframework is git-ignored;
# ci_scripts/install_dusk_dovi.sh calls this only when the sources changed.
#
# Uses rustup with the toolchain pinned in rust-toolchain.toml. Never call a
# bare `cargo`: Homebrew's cargo/rustc are often first on PATH and ship no
# iOS/tvOS standard library.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT_DIR}/Native/DuskDovi"
OUTPUT_DIR="${ROOT_DIR}/Frameworks/DuskDovi.xcframework"
STAGE_DIR="${ROOT_DIR}/.build/dusk-dovi-stage"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-tvos aarch64-apple-tvos-sim aarch64-apple-darwin x86_64-apple-darwin)
MACOS_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)

TOOLCHAIN="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "${CRATE_DIR}/rust-toolchain.toml")"

if [ -x "${CARGO_HOME:-${HOME}/.cargo}/bin/rustup" ]; then
    RUSTUP="${CARGO_HOME:-${HOME}/.cargo}/bin/rustup"
elif command -v rustup >/dev/null 2>&1; then
    RUSTUP="$(command -v rustup)"
else
    echo "error: rustup not found. Install it from https://rustup.rs, then rerun." >&2
    exit 1
fi

# The minimum OS versions follow project.yml so the archives never target a
# newer OS than the apps.
deployment_target() {
    sed -n "s/^    $1: *\"\(.*\)\"/\1/p" "${ROOT_DIR}/project.yml" | head -1
}
IPHONEOS_DEPLOYMENT_TARGET="$(deployment_target iOS)"
TVOS_DEPLOYMENT_TARGET="$(deployment_target tvOS)"
MACOSX_DEPLOYMENT_TARGET="$(deployment_target macOS)"
if [ -z "${TOOLCHAIN}" ] || [ -z "${IPHONEOS_DEPLOYMENT_TARGET}" ] || [ -z "${TVOS_DEPLOYMENT_TARGET}" ] || [ -z "${MACOSX_DEPLOYMENT_TARGET}" ]; then
    echo "error: could not read the Rust toolchain or the deployment targets." >&2
    exit 1
fi
export IPHONEOS_DEPLOYMENT_TARGET TVOS_DEPLOYMENT_TARGET MACOSX_DEPLOYMENT_TARGET

installed_targets="$("${RUSTUP}" target list --installed --toolchain "${TOOLCHAIN}" 2>/dev/null || true)"
for target in "${TARGETS[@]}"; do
    if ! grep -qx "${target}" <<<"${installed_targets}"; then
        targets_csv="$(IFS=,; echo "${TARGETS[*]}")"
        "${RUSTUP}" toolchain install "${TOOLCHAIN}" --profile minimal --target "${targets_csv}"
        break
    fi
done

# Xcode and CI environments can leak settings meant for other builds; the
# host-side build scripts of dependencies must still compile for macOS.
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS RUSTC_WRAPPER CARGO_BUILD_TARGET SDKROOT
export CARGO_TARGET_DIR="${ROOT_DIR}/.build/dusk-dovi-target"

# Recent rustup no longer puts the toolchain first on PATH for `rustup run`,
# so cargo would pick up Homebrew's rustc. Pin both binaries explicitly.
CARGO="$("${RUSTUP}" which cargo --toolchain "${TOOLCHAIN}")"
RUSTC="$("${RUSTUP}" which rustc --toolchain "${TOOLCHAIN}")"
PATH="$(dirname "${RUSTC}"):${PATH}"
export RUSTC PATH

create_args=()
for target in "${TARGETS[@]}"; do
    echo "Building DuskDovi for ${target}..."
    "${CARGO}" build \
        --manifest-path "${CRATE_DIR}/Cargo.toml" \
        --release --locked --target "${target}"
    mkdir -p "${STAGE_DIR}/${target}"
    cp "${CARGO_TARGET_DIR}/${target}/release/libdusk_dovi.a" "${STAGE_DIR}/${target}/"
    xcrun strip -S "${STAGE_DIR}/${target}/libdusk_dovi.a"
    case "${target}" in
        *-apple-darwin) ;;  # merged into one macOS slice below
        *) create_args+=(-library "${STAGE_DIR}/${target}/libdusk_dovi.a" -headers "${CRATE_DIR}/include") ;;
    esac
done

mkdir -p "${STAGE_DIR}/macos"
macos_libs=()
for target in "${MACOS_TARGETS[@]}"; do
    macos_libs+=("${STAGE_DIR}/${target}/libdusk_dovi.a")
done
xcrun lipo -create "${macos_libs[@]}" -output "${STAGE_DIR}/macos/libdusk_dovi.a"
create_args+=(-library "${STAGE_DIR}/macos/libdusk_dovi.a" -headers "${CRATE_DIR}/include")

rm -rf "${OUTPUT_DIR}"
mkdir -p "${ROOT_DIR}/Frameworks"
xcodebuild -create-xcframework "${create_args[@]}" -output "${OUTPUT_DIR}"

echo "DuskDovi.xcframework built at ${OUTPUT_DIR}."
