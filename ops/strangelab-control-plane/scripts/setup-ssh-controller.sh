#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/tools/_env.sh"

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [mac2_host_or_ip]"
  exit 1
fi

if [[ $# -eq 1 ]]; then
  MAC2_HOST="$1"
fi
CTRL_KEY="$HOME/.ssh/strangelab_controller"
CONFIG_FILE="$HOME/.ssh/config"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [[ ! -f "$CTRL_KEY" ]]; then
  ssh-keygen -t ed25519 -f "$CTRL_KEY" -N "" -C "strangelab-controller"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  touch "$CONFIG_FILE"
fi

append_host() {
  local name="$1"
  local host="$2"
  if ! grep -q "Host ${name}$" "$CONFIG_FILE"; then
    cat >>"$CONFIG_FILE" <<CFG
Host ${name}
  HostName ${host}
  User strangelab
  IdentityFile ${CTRL_KEY}
  IdentitiesOnly yes
CFG
  fi
}

append_host "strangelab-pi-aux" "$AUX_HOST"
append_host "strangelab-pi-logger" "$LOGGER_HOST"
append_host "strangelab-mac-2" "$MAC2_HOST"

# Human-friendly aliases (same controller key + ssh-guard user).
# These do not replace the canonical "strangelab-*" aliases, they just add shortcuts.
append_host "aux" "$AUX_HOST"
append_host "aux-5g" "$AUX_5G_HOST"
append_host "aux-24g" "$AUX_24G_HOST"

append_host "vault" "$VAULT_HOST"
append_host "vault-eth" "$VAULT_ETH_HOST"
append_host "vault-wifi" "$VAULT_WIFI_HOST"

append_host "mac16" "$MAC16_HOST"
append_host "mac8" "$MAC8_HOST"
chmod 600 "$CONFIG_FILE"

mkdir -p "$HOME/.local/bin"
cat >"$HOME/.local/bin/sl-ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: sl-ssh <host_alias> <request_id> <cmd> [args...]"
  exit 2
fi

HOST="$1"; shift
RID="$1"; shift
CMD="$1"; shift

ARGS_JSON=$(python3 - "$@" <<'PY'
import json, sys
print(json.dumps(sys.argv[1:]))
PY
)

REQ=$(python3 - "$RID" "$CMD" "$ARGS_JSON" <<'PY'
import json, sys
rid, cmd, args = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
print(json.dumps({
  "id": rid,
  "cmd": cmd,
  "args": args,
  "cwd": ".",
  "timeout_ms": 30000
}))
PY
)

echo "$REQ" | ssh "$HOST"
SH
chmod +x "$HOME/.local/bin/sl-ssh"

echo "controller ready"
echo "public key: $CTRL_KEY.pub"
echo "use aliases: strangelab-pi-aux, strangelab-pi-logger, strangelab-mac-2, aux, aux-5g, aux-24g, vault, vault-eth, vault-wifi, mac16, mac8"
echo "sl-ssh: $HOME/.local/bin/sl-ssh"
