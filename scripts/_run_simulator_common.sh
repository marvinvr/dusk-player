#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/.build/sim-derived-data}"
BUNDLE_ID="com.dusk-player.app"

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

find_or_create_device() {
  local device_name="$1"
  local device_type_id="$2"
  local runtime_prefix="$3"
  local device_uuid
  local runtime_id

  device_uuid="$(
    xcrun simctl list devices available |
      grep -F "    $device_name (" |
      grep -oE '[A-F0-9-]{36}' |
      head -n 1 || true
  )"

  if [[ -n "$device_uuid" ]]; then
    printf '%s\n' "$device_uuid"
    return
  fi

  runtime_id="$(
    xcrun simctl list runtimes |
      awk -F ' - ' -v prefix="$runtime_prefix" '$1 ~ ("^" prefix " ") { print $2; exit }'
  )"

  if [[ -z "$runtime_id" ]]; then
    echo "Could not find an installed runtime for $runtime_prefix" >&2
    exit 1
  fi

  xcrun simctl create "$device_name" "$device_type_id" "$runtime_id"
}

boot_device() {
  local device_uuid="$1"

  open -a Simulator >/dev/null 2>&1 || true
  xcrun simctl boot "$device_uuid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$device_uuid" -b
}

build_ios_app() {
  local device_uuid="$1"

  xcodebuild \
    -project "$REPO_ROOT/Dusk.xcodeproj" \
    -scheme Dusk \
    -configuration Debug \
    -destination "id=$device_uuid" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    build
}

build_tvos_app() {
  local device_uuid="$1"

  xcodebuild \
    -project "$REPO_ROOT/Dusk.xcodeproj" \
    -scheme Dusk-tvOS \
    -configuration Debug \
    -destination "id=$device_uuid" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
}

check_ios_build() {
  xcodebuild \
    -project "$REPO_ROOT/Dusk.xcodeproj" \
    -scheme Dusk \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    build
}

check_tvos_build() {
  xcodebuild \
    -project "$REPO_ROOT/Dusk.xcodeproj" \
    -scheme Dusk-tvOS \
    -configuration Debug \
    -destination 'generic/platform=tvOS Simulator' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
}

install_and_launch_app() {
  local device_uuid="$1"
  local app_path="$2"

  xcrun simctl install "$device_uuid" "$app_path"
  xcrun simctl launch "$device_uuid" "$BUNDLE_ID"
}

run_ios_simulator() {
  local device_name="$1"
  local device_type_id="$2"
  local device_uuid
  local app_path="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/Dusk.app"

  device_uuid="$(find_or_create_device "$device_name" "$device_type_id" "iOS")"

  echo "Using simulator: $device_name ($device_uuid)"
  boot_device "$device_uuid"
  build_ios_app "$device_uuid"
  install_and_launch_app "$device_uuid" "$app_path"
}

run_tvos_simulator() {
  local device_name="$1"
  local device_type_id="$2"
  local device_uuid
  local app_path="$DERIVED_DATA_PATH/Build/Products/Debug-appletvsimulator/Dusk.app"

  device_uuid="$(find_or_create_device "$device_name" "$device_type_id" "tvOS")"

  echo "Using simulator: $device_name ($device_uuid)"
  boot_device "$device_uuid"
  build_tvos_app "$device_uuid"
  install_and_launch_app "$device_uuid" "$app_path"
}

require_command xcodebuild
require_command xcrun
