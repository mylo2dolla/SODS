#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tools/_env.sh"

MODE="${1:-outbox}"
DRY_RUN="${DRY_RUN:-0}"

if [[ "${MODE}" == "--help" || "${MODE}" == "-h" ]]; then
  cat <<'USAGE'
vaultsync.sh [outbox|all]  (env: DRY_RUN=1)

Ships local runtime data to Vault over SSH.

Defaults:
  - Runtime root resolves from $SODS_ROOT (fallbacks from tools/_env.sh)
  - Ships only: <runtime-root>/.shipper/outbox -> $VAULT_SYNC_DEST (date-partitioned)
  - "all" also ships: <runtime-root>/inbox, <runtime-root>/workspace, <runtime-root>/reports
  - Runtime outputs are operational artifacts and should remain local (not committed)

Environment:
  VAULT_SYNC_SSH      SSH target (default: $VAULT_SSH_TARGET)
  VAULT_SYNC_DEST     Remote base directory (default: ~/sods/vault/sods)
  DRY_RUN=1           Print actions without transferring
USAGE
  exit 0
fi

VAULT_SYNC_SSH="${VAULT_SYNC_SSH:-${VAULT_SSH_TARGET:-}}"
if [[ -z "${VAULT_SYNC_SSH}" ]]; then
  echo "vaultsync: missing VAULT_SYNC_SSH/VAULT_SSH_TARGET" >&2
  exit 2
fi

VAULT_SYNC_DEST="${VAULT_SYNC_DEST:-${VAULT_DEST_PATH:-~/sods/vault/sods}}"

RUNTIME_ROOT="${SODS_ROOT:-$REPO_ROOT}"
OUTBOX="$RUNTIME_ROOT/.shipper/outbox"
INBOX="$RUNTIME_ROOT/inbox"
WORKSPACE="$RUNTIME_ROOT/workspace"
REPORTS="$RUNTIME_ROOT/reports"

today_utc="$(TZ=UTC date +%Y/%m/%d)"
remote_base="${VAULT_SYNC_DEST%/}"
remote_day="$remote_base/$today_utc"

ssh_flags=(-o BatchMode=yes -o ConnectTimeout=8)

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "+ $*"
    return 0
  fi
  "$@"
}

ensure_remote_dir() {
  local dir="$1"
  run ssh "${ssh_flags[@]}" "$VAULT_SYNC_SSH" "mkdir -p \"${dir}\" && test -w \"${dir}\""
}

ship_tree() {
  local src="$1"
  local dest_dir="$2"
  if [[ ! -d "$src" ]]; then
    echo "vaultsync: skip missing dir: $src" >&2
    return 0
  fi
  local rsync="/usr/bin/rsync"
  if [[ -x "$rsync" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      run "$rsync" -az --delete --dry-run --exclude ".DS_Store" --exclude "node_modules" \
        "$src/." "${VAULT_SYNC_SSH}:\"${dest_dir}/\""
    else
      run "$rsync" -az --delete --exclude ".DS_Store" --exclude "node_modules" \
        "$src/." "${VAULT_SYNC_SSH}:\"${dest_dir}/\""
    fi
    return 0
  fi
  echo "vaultsync: rsync not found; falling back to scp (no delete)" >&2
  run /usr/bin/scp -r "$src/." "${VAULT_SYNC_SSH}:\"${dest_dir}/\""
}

echo "vaultsync: ssh=$VAULT_SYNC_SSH"
echo "vaultsync: dest=$remote_day"
echo "vaultsync: runtime_root=$RUNTIME_ROOT"
echo "vaultsync: mode=$MODE dry_run=$DRY_RUN"

ensure_remote_dir "$remote_day"

case "$MODE" in
  outbox)
    ship_tree "$OUTBOX" "$remote_day/outbox"
    ;;
  all)
    ship_tree "$OUTBOX" "$remote_day/outbox"
    ship_tree "$INBOX" "$remote_day/inbox"
    ship_tree "$WORKSPACE" "$remote_day/workspace"
    ship_tree "$REPORTS" "$remote_day/reports"
    ;;
  *)
    echo "vaultsync: unknown mode: $MODE" >&2
    exit 2
    ;;
esac

echo "vaultsync: done"
