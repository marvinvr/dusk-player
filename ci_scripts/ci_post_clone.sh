#!/bin/bash
set -euo pipefail

# Xcode Cloud runs this immediately after cloning the repository and before the
# build starts.
#
# The MobileVLCKit/TVVLCKit xcframeworks (~140 MB of prebuilt binaries) are
# intentionally NOT committed to git (see .gitignore). Fetch and stage the
# pinned, checksum-verified build so the Xcode build can link against them.
# install_vlckit.sh installs BOTH the iOS and tvOS frameworks, so a single run
# covers every platform and workflow.

ROOT_DIR="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

"${ROOT_DIR}/ci_scripts/install_vlckit.sh"

# Fail loudly and early if the frameworks did not end up in place — a clear
# message here beats a cryptic "There is no XCFramework found at ..." from the
# linker later in the build.
for framework in MobileVLCKit TVVLCKit; do
    if [ ! -d "${ROOT_DIR}/Frameworks/${framework}.xcframework" ]; then
        echo "error: ${framework}.xcframework is missing after install_vlckit.sh." >&2
        exit 1
    fi
done

echo "VLCKit frameworks staged; the build can now link MobileVLCKit and TVVLCKit."
