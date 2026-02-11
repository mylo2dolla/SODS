#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

"$REPO_ROOT/tools/devstation-build.sh"
"$REPO_ROOT/tools/devstation-install.sh"
"$REPO_ROOT/tools/install-devstation-launcher.sh"

echo "Dev Station packaged."
echo "App: /Applications/Dev Station.app"
echo "Launcher: /Applications/DevStation Stack.app"
