#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <ssh-host> <profile>"
  echo "profiles: pi-aux | pi-logger"
  exit 1
fi

SSH_HOST="$1"
PROFILE="$2"
LOCAL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_ROOT="~/strangelab-control-plane"

rsync -az --delete "$LOCAL_ROOT/" "$SSH_HOST:$REMOTE_ROOT/"

case "$PROFILE" in
  pi-aux)
    ssh "$SSH_HOST" "bash $REMOTE_ROOT/scripts/install-pi-aux.sh"
    ;;
  pi-logger)
    ssh "$SSH_HOST" "bash $REMOTE_ROOT/scripts/install-pi-logger.sh"
    ;;
  *)
    echo "unknown profile: $PROFILE"
    exit 1
    ;;
esac
