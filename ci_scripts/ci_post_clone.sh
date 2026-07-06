#!/bin/bash
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

if [ ! -d "Frameworks/MobileVLCKit.xcframework" ]; then
    echo "Vendored MobileVLCKit.xcframework is missing from the repository checkout."
    exit 1
fi

if [ ! -d "Frameworks/TVVLCKit.xcframework" ]; then
    echo "Vendored TVVLCKit.xcframework is missing from the repository checkout."
    exit 1
fi

echo "Using vendored MobileVLCKit and TVVLCKit frameworks from the repository."
