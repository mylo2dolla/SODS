#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

remove_path() {
  local target="$1"
  if [[ -e "$target" || -L "$target" ]]; then
    rm -rf "$target"
    echo "removed: $target"
  fi
}

# Old launcher app names and stale desktop artifacts.
remove_path "/Applications/Devstation.app"
remove_path "/Applications/DevStation Start.app"
remove_path "/Applications/Vogon Start.app"
remove_path "$HOME/Applications/Devstation.app"
remove_path "$HOME/Applications/DevStation Start.app"
remove_path "$HOME/Applications/Vogon Start.app"
remove_path "$HOME/Desktop/Vogon Shortcuts/Vogon Start.app"
remove_path "$HOME/Desktop/Vogon Shortcuts/Vogon Start.app.scpt"
remove_path "$HOME/Desktop/Vogon Shortcuts/Devstation.app"

# Stale duplicate app scaffold left over from earlier experiments.
remove_path "$REPO_ROOT/apps/letsdev-studio"

echo "old Dev Station assets cleanup complete"
