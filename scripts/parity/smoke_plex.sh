#!/usr/bin/env bash
# G6 (docs/jellyfin/05-plan.md §3): plex-demo smoke as the comparison user
# through smoke_proxy.py. Baseline is machine-local (~/.cache/dusk-parity).
# Usage: smoke_plex.sh [check|record|repeat] [gate.py options]  (PLATFORMS=iphone,tv after recording tv)
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/gate.py" smoke "${1:-check}" --platforms "${PLATFORMS:-iphone}" "${@:2}"
