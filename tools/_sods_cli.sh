#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_DIR="$ROOT/cli/sods"
DIST="$CLI_DIR/dist/cli.js"

is_missing() {
  [[ ! -f "$DIST" ]]
}

is_stale() {
  [[ ! -f "$DIST" ]] && return 0
  local dist_ts
  dist_ts=$(stat -f%m "$DIST")

  local candidate
  while IFS= read -r candidate; do
    local ts
    ts=$(stat -f%m "$candidate" 2>/dev/null || true)
    if [[ -n "$ts" && "$ts" -gt "$dist_ts" ]]; then
      return 0
    fi
  done < <(
    find "$CLI_DIR/src" -type f \
      -o -path "$CLI_DIR/package.json" \
      -o -path "$CLI_DIR/package-lock.json"
  )

  return 1
}

ensure_deps() {
  if [[ ! -d "$CLI_DIR/node_modules" ]]; then
    (cd "$CLI_DIR" && npm install)
  fi
}

if is_missing || is_stale; then
  ensure_deps
  (cd "$CLI_DIR" && npm run build)
fi

exec node "$DIST" "$@"
