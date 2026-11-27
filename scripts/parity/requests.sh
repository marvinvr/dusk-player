#!/usr/bin/env bash
# G2 + G3 (docs/jellyfin/05-plan.md §3). One driver run produces both the
# request logs (G2) and the screenshots (G3); screens.sh is the same command.
# Usage: requests.sh [check|record|repeat] [gate.py options]
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/gate.py" screens "${1:-check}" "${@:2}"
