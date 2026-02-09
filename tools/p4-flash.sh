#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJ_DIR="$REPO_ROOT/firmware/sods-p4-godbutton"

if [[ ! -d "$PROJ_DIR" ]]; then
  echo "p4-flash: project not found at $PROJ_DIR" >&2
  exit 2
fi

VERSION="${FW_VERSION:-}"
PORT_ARG="${PORT:-auto}"
ERASE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --port)
      PORT_ARG="${2:-auto}"
      shift 2
      ;;
    --erase)
      ERASE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "p4-flash: unknown arg '$1'" >&2
      echo "usage: $0 [--version <ver>] [--port <tty|auto>] [--erase] [--dry-run]" >&2
      exit 64
      ;;
  esac
done

ARGS=(./tools/flash.mjs --board waveshare-esp32p4 --port "$PORT_ARG")
if [[ -n "$VERSION" ]]; then
  ARGS+=(--version "$VERSION")
fi
if [[ "$ERASE" -eq 1 ]]; then
  ARGS+=(--erase)
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  ARGS+=(--dry-run)
fi

cd "$PROJ_DIR"
node "${ARGS[@]}"
