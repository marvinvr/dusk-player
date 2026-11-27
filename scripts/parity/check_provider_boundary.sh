#!/usr/bin/env bash
# G7 (docs/jellyfin/05-plan.md §3): no provider names outside Providers/ and
# the sign-in flow. Enforced from P0-19 on; until then it reports.
#
#   check_provider_boundary.sh            # report: count per top-level folder, exit 0
#   check_provider_boundary.sh --enforce  # list every hit, exit 1 if any
#
# Allowed paths (relative to Dusk/Sources, one extended regex per line) live
# in scripts/parity/provider_boundary_allowlist.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCES="$ROOT/Dusk/Sources"
ALLOWLIST="$ROOT/scripts/parity/provider_boundary_allowlist.txt"
# Type and API names of a provider: PlexItem, plexService, plex.tv, Jellyfin…
PATTERN='\b([Pp]lex[A-Z_]|[Pp]lex\b|plex\.tv|[Jj]ellyfin)'

allowed() {
  local file="$1"
  [[ -f "$ALLOWLIST" ]] || return 1
  while IFS= read -r rule; do
    [[ -z "$rule" || "$rule" == \#* ]] && continue
    [[ "$file" =~ $rule ]] && return 0
  done <"$ALLOWLIST"
  return 1
}

hits=()
while IFS= read -r line; do
  file="${line%%:*}"
  allowed "$file" || hits+=("$line")
done < <(cd "$SOURCES" && grep -rnE "$PATTERN" --include='*.swift' . | sed 's|^\./||' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)

if [[ "${1:-}" == "--enforce" ]]; then
  if ((${#hits[@]})); then
    printf '%s\n' "${hits[@]}"
    echo "G7 FAILED: ${#hits[@]} provider-name hits outside the allowed paths" >&2
    exit 1
  fi
  echo "G7: no provider names outside the allowed paths"
  exit 0
fi

echo "G7 report (not enforced before P0-19): ${#hits[@]} hits outside the allowed paths"
if ((${#hits[@]})); then
  printf '%s\n' "${hits[@]}" | cut -d/ -f1 | cut -d: -f1 | sort | uniq -c | sort -rn
fi
