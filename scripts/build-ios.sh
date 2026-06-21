#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_run_simulator_common.sh
source "$SCRIPT_DIR/_run_simulator_common.sh"

check_ios_build
