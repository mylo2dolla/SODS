#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/tools"

if [[ ! -d "$TOOLS_DIR" ]]; then
  echo "permfix: tools directory not found at $TOOLS_DIR" >&2
  exit 2
fi

targets=(
  "$TOOLS_DIR/_sods_cli.sh"
  "$TOOLS_DIR/sods"
  "$TOOLS_DIR/devstation"
  "$TOOLS_DIR/cockpit"
  "$TOOLS_DIR/camutil"
  "$TOOLS_DIR/permfix.sh"
  "$TOOLS_DIR/wifi-scan.sh"
  "$TOOLS_DIR/dev.sh"
  "$TOOLS_DIR/devstation-build.sh"
  "$TOOLS_DIR/devstation-run.sh"
  "$TOOLS_DIR/devstation-install.sh"
  "$TOOLS_DIR/devstation-rebuild.sh"
  "$TOOLS_DIR/audit-tools.sh"
  "$TOOLS_DIR/audit-repo.sh"
  "$TOOLS_DIR/launchagent-install.sh"
  "$TOOLS_DIR/launchagent-uninstall.sh"
  "$TOOLS_DIR/launchagent-status.sh"
  "$TOOLS_DIR/smoke.sh"
  "$TOOLS_DIR/portal-cyd-build.sh"
  "$TOOLS_DIR/portal-cyd-stage.sh"
  "$TOOLS_DIR/portal-build.sh"
  "$TOOLS_DIR/portal-flash-help.sh"
  "$TOOLS_DIR/p4-build.sh"
  "$TOOLS_DIR/p4-flash.sh"
  "$TOOLS_DIR/p4-monitor.sh"
  "$TOOLS_DIR/verify.sh"
)

for target in "${targets[@]}"; do
  if [[ -e "$target" ]]; then
    chmod +x "$target"
  else
    echo "permfix: missing $target" >&2
  fi
done
