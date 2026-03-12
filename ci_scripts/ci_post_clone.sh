#!/bin/bash
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

if [ ! -d "Frameworks/MobileVLCKit.xcframework" ]; then
    echo "Downloading MobileVLCKit 3.7.2..."
    mkdir -p Frameworks && cd Frameworks
    curl -L -o MobileVLCKit.tar.xz "https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.2-3e42ae47-79128878.tar.xz"
    tar xf MobileVLCKit.tar.xz && rm MobileVLCKit.tar.xz
    mv MobileVLCKit-binary/MobileVLCKit.xcframework .
    mv MobileVLCKit-binary/COPYING.txt VLCKit-LICENSE.txt
    rm -rf MobileVLCKit-binary
    echo "MobileVLCKit.xcframework downloaded."
else
    echo "MobileVLCKit.xcframework already present."
fi
