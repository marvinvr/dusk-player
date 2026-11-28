#!/usr/bin/env bash
# G7 (docs/jellyfin/05-plan.md §3, 04 §5.4): outside Providers/ and the
# sign-in flow, no Swift code names a provider type (`Plex…` / `Jellyfin…`
# followed by a capital), `ProviderKind`, or an `X-Plex` header. Comment lines
# are skipped; string literals are not, so a header or key built in neutral
# code is caught.
#
#   check_provider_boundary.sh            # report: count per top-level folder, exit 0
#   check_provider_boundary.sh --enforce  # list every hit, exit 1 if any (the gate)
#
# Exceptions live in scripts/parity/provider_boundary_allowlist.txt, one per
# line: `<path regex>` allows a whole path, `<path regex> :: <match regex>`
# allows only matching hits in that path. Paths are relative to Dusk/Sources.
# Every exception carries its reason; keep the list short.
#
# Lower-camel member names (`plexAccount`, `plexTVRequest`) and user-facing
# copy that says "Plex" are not matched: 04 §5.4 defines the check on type
# names. Before P0-19 this script reported on a wider pattern that included
# them; that report is gone with the enforced gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCES="$ROOT/Dusk/Sources"
ALLOWLIST="$ROOT/scripts/parity/provider_boundary_allowlist.txt"
PATTERN='\b(Plex[A-Z][A-Za-z0-9_]*|Jellyfin[A-Z][A-Za-z0-9_]*|ProviderKind)\b|X-Plex'

paths=()
pairs_path=()
pairs_match=()
if [[ -f "$ALLOWLIST" ]]; then
  while IFS= read -r rule; do
    [[ -z "${rule//[[:space:]]/}" || "$rule" == \#* ]] && continue
    if [[ "$rule" == *" :: "* ]]; then
      pairs_path+=("${rule%% :: *}")
      pairs_match+=("${rule#* :: }")
    else
      paths+=("$rule")
    fi
  done <"$ALLOWLIST"
fi

allowed() {
  local file="$1" text="$2" rule i match
  for rule in ${paths[@]+"${paths[@]}"}; do
    [[ "$file" =~ $rule ]] && return 0
  done
  for i in "${!pairs_path[@]}"; do
    [[ "$file" =~ ${pairs_path[$i]} ]] || continue
    # Every provider name on the line must be one this rule allows.
    local others
    others="$(grep -oE "$PATTERN" <<<"$text" | grep -vE "^(${pairs_match[$i]})$" || true)"
    [[ -z "$others" ]] && return 0
  done
  return 1
}

hits=()
while IFS= read -r line; do
  file="${line%%:*}"
  rest="${line#*:}"
  text="${rest#*:}"
  allowed "$file" "$text" || hits+=("$line")
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

echo "G7 report: ${#hits[@]} hits outside the allowed paths"
if ((${#hits[@]})); then
  printf '%s\n' "${hits[@]}" | cut -d/ -f1 | cut -d: -f1 | sort | uniq -c | sort -rn
fi
