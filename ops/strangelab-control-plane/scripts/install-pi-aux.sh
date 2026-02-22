#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [[ -f "$REPO_ROOT/tools/_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/_env.sh"
fi
UFW_CIDR="${UFW_CIDR:-${AUX_CIDR:-192.168.8.0/24}}"

ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="/opt/strangelab"

if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get update
  sudo apt-get install -y nodejs
fi

sudo mkdir -p "$TARGET_DIR"
sudo cp "$ROOT_DIR/agents/token-server.mjs" "$TARGET_DIR/token-server.mjs"
sudo cp "$ROOT_DIR/agents/god-gateway.mjs" "$TARGET_DIR/god-gateway.mjs"
sudo cp "$ROOT_DIR/agents/ops-feed.mjs" "$TARGET_DIR/ops-feed.mjs"
sudo cp "$ROOT_DIR/package.json" "$TARGET_DIR/package.json"
sudo cp "$ROOT_DIR/config/federation-targets.json" "$TARGET_DIR/federation-targets.json"

pushd "$TARGET_DIR" >/dev/null
sudo npm install --omit=dev
popd >/dev/null

sudo cp "$ROOT_DIR/services/systemd/strangelab-token.service" /etc/systemd/system/strangelab-token.service
sudo cp "$ROOT_DIR/services/systemd/strangelab-god-gateway.service" /etc/systemd/system/strangelab-god-gateway.service
sudo cp "$ROOT_DIR/services/systemd/strangelab-ops-feed.service" /etc/systemd/system/strangelab-ops-feed.service
sudo cp "$ROOT_DIR/services/systemd/strangelab-codegatchi-tunnel.service" /etc/systemd/system/strangelab-codegatchi-tunnel.service

sudo mkdir -p /etc/strangelab
default_tunnel_host="${FED_TUNNEL_HOST:-letsdev@192.168.8.214}"
default_logger_host="${LOGGER_HOST:-192.168.8.160}"
default_remote_host="${REMOTE_HOST:-pi@${default_logger_host}}"
cat <<ENV | sudo tee /etc/strangelab/codegatchi-tunnel.env >/dev/null
FED_TUNNEL_HOST=$default_tunnel_host
FED_TUNNEL_LOCAL_PORT=${FED_TUNNEL_LOCAL_PORT:-9777}
FED_TUNNEL_REMOTE_PORT=${FED_TUNNEL_REMOTE_PORT:-9777}
ENV

cat <<ENV | sudo tee /etc/strangelab/ops-feed.env >/dev/null
REMOTE_HOST=$default_remote_host
LOGGER_HOST=$default_logger_host
ENV

federation_bearer="${FED_GATEWAY_BEARER:-}"
if [[ -z "$federation_bearer" ]]; then
  federation_bearer="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$default_tunnel_host" 'security find-generic-password -s com.dev.codegatchi.gateway -a codegatchi.gateway.token.v1 -w' 2>/dev/null || true)"
fi
if [[ -n "$federation_bearer" ]]; then
  {
    echo "FED_GATEWAY_BEARER=$federation_bearer"
    echo "FED_GATEWAY_URL=${FED_GATEWAY_URL:-http://127.0.0.1:9777}"
    echo "FED_GATEWAY_HEALTH_URL=${FED_GATEWAY_HEALTH_URL:-http://127.0.0.1:9777/v1/health}"
    echo "FED_TARGETS_FILE=/opt/strangelab/federation-targets.json"
  } | sudo tee /etc/strangelab/god-gateway.env >/dev/null
  {
    echo "FED_GATEWAY_BEARER=$federation_bearer"
    echo "FED_GATEWAY_HEALTH_URL=${FED_GATEWAY_HEALTH_URL:-http://127.0.0.1:9777/v1/health}"
  } | sudo tee /etc/strangelab/token.env >/dev/null
else
  echo "warn: unable to fetch Codegatchi gateway bearer token; set FED_GATEWAY_BEARER in /etc/strangelab/god-gateway.env" >&2
fi

if [[ -d "$TARGET_DIR/livekit" ]]; then
  (cd "$TARGET_DIR/livekit" && sudo docker compose down) >/dev/null 2>&1 || true
fi
sudo systemctl disable --now strangelab-exec-agent@pi-aux.service >/dev/null 2>&1 || true
sudo systemctl disable --now strangelab-exec-agent.service >/dev/null 2>&1 || true

sudo systemctl daemon-reload
sudo systemctl enable strangelab-codegatchi-tunnel.service
sudo systemctl enable strangelab-token.service
sudo systemctl enable strangelab-god-gateway.service
sudo systemctl enable strangelab-ops-feed.service

sudo systemctl restart strangelab-codegatchi-tunnel.service
sudo systemctl restart strangelab-token.service
sudo systemctl restart strangelab-god-gateway.service
sudo systemctl restart strangelab-ops-feed.service

if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow from "$UFW_CIDR" to any port 9101 proto tcp >/dev/null 2>&1 || true
fi

sudo systemctl --no-pager --full status strangelab-codegatchi-tunnel.service | sed -n '1,40p'
sudo systemctl --no-pager --full status strangelab-token.service | sed -n '1,40p'
sudo systemctl --no-pager --full status strangelab-god-gateway.service | sed -n '1,40p'
sudo systemctl --no-pager --full status strangelab-ops-feed.service | sed -n '1,40p'

if [[ -n "$federation_bearer" ]]; then
  curl -fsS --max-time 8 -H "Authorization: Bearer ${federation_bearer}" http://127.0.0.1:9777/v1/health >/dev/null
else
  health_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:9777/v1/health || true)"
  if [[ "$health_code" != "200" && "$health_code" != "401" ]]; then
    echo "error: codegatchi health probe failed (http=${health_code:-none})" >&2
    exit 22
  fi
fi
curl -fsS --max-time 8 http://127.0.0.1:9123/health >/dev/null
curl -fsS --max-time 8 http://127.0.0.1:8099/health >/dev/null

bash "$ROOT_DIR/scripts/install-control-surface.sh"

echo "pi-aux install complete (federation compatibility mode)"
