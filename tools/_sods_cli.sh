#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI_DIR="$REPO_ROOT/cli/sods"
DIST="$CLI_DIR/dist/cli.js"

resolve_node() {
  if command -v node >/dev/null 2>&1; then
    command -v node
    return 0
  fi
  if [[ -x "/opt/homebrew/bin/node" ]]; then
    echo "/opt/homebrew/bin/node"
    return 0
  fi
  if [[ -x "/usr/local/bin/node" ]]; then
    echo "/usr/local/bin/node"
    return 0
  fi
  return 1
}

if [[ ! -d "$CLI_DIR" ]]; then
  echo "sods: CLI directory not found at $CLI_DIR" >&2
  exit 2
fi
if [[ ! -f "$CLI_DIR/package.json" ]]; then
  echo "sods: package.json missing in $CLI_DIR" >&2
  exit 2
fi
if [[ ! -d "$CLI_DIR/src" ]]; then
  echo "sods: src directory missing in $CLI_DIR" >&2
  exit 2
fi

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
  done < <(find "$CLI_DIR/src" -type f)

  for candidate in "$CLI_DIR/package.json" "$CLI_DIR/package-lock.json"; do
    if [[ -f "$candidate" ]]; then
      local ts
      ts=$(stat -f%m "$candidate" 2>/dev/null || true)
      if [[ -n "$ts" && "$ts" -gt "$dist_ts" ]]; then
        return 0
      fi
    fi
  done

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

NODE_BIN="$(resolve_node || true)"
if [[ -z "${NODE_BIN:-}" ]]; then
  echo "sods: node runtime not found (checked PATH, /opt/homebrew/bin/node, /usr/local/bin/node)" >&2
  exit 127
fi

exec "$NODE_BIN" "$DIST" "$@"
