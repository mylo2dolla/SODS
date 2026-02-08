#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [[ -f "$REPO_ROOT/tools/_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/_env.sh"
fi
LOGGER_HOST="${LOGGER_HOST:-192.168.8.160}"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <controller_pubkey_path> <pi-aux|pi-logger|allowlist.json> [node_id]"
  exit 1
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PUBKEY_PATH="$1"
ALLOW_SRC="$2"
NODE_ID="${3:-$(hostname -s)}"
VAULT_INGEST_URL="${VAULT_INGEST_URL:-http://${LOGGER_HOST}:8088/v1/ingest}"

if [[ ! -f "$PUBKEY_PATH" ]]; then
  echo "missing pubkey file: $PUBKEY_PATH"
  exit 1
fi

if [[ "$ALLOW_SRC" == "pi-aux" || "$ALLOW_SRC" == "pi-logger" ]]; then
  ALLOWLIST_TEMPLATE="$ROOT_DIR/services/allowlist/${ALLOW_SRC}.json"
else
  ALLOWLIST_TEMPLATE="$ALLOW_SRC"
fi

if [[ ! -f "$ALLOWLIST_TEMPLATE" ]]; then
  echo "missing allowlist template: $ALLOWLIST_TEMPLATE"
  exit 1
fi

sudo useradd -m -s /usr/sbin/nologin strangelab >/dev/null 2>&1 || true
sudo mkdir -p /home/strangelab/.ssh /opt/strangelab
sudo chmod 700 /home/strangelab/.ssh
sudo chown -R strangelab:strangelab /home/strangelab/.ssh

sudo cp "$ALLOWLIST_TEMPLATE" /opt/strangelab/allowlist.json
sudo chmod 644 /opt/strangelab/allowlist.json

sudo install -m 755 /dev/stdin /usr/local/bin/strangelab-ssh-guard <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/default/strangelab-ssh-guard ]]; then
  # shellcheck disable=SC1091
  source /etc/default/strangelab-ssh-guard
fi

LOGGER_HOST="${LOGGER_HOST:-192.168.8.160}"
VAULT_INGEST_URL="${VAULT_INGEST_URL:-http://${LOGGER_HOST}:8088/v1/ingest}"
NODE_ID="${NODE_ID:-$(hostname -s)}"
ALLOWLIST="${ALLOWLIST:-/opt/strangelab/allowlist.json}"

read -r LINE || { echo '{"ok":false,"error":"no input"}'; exit 2; }

python3 - "$LINE" "$ALLOWLIST" "$VAULT_INGEST_URL" "$NODE_ID" <<'PY'
import hashlib
import ipaddress
import json
import os
import subprocess
import sys
import time
import urllib.request

MAX_OUTPUT_BYTES = 256 * 1024
line, allowlist_path, vault_url, node_id = sys.argv[1:5]

def out(obj, code=0):
    print(json.dumps(obj))
    sys.exit(code)

def sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()

def load_allowlist(path: str):
    if not os.path.exists(path):
        return None, "ALLOWLIST_MISSING", "allowlist missing"
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return None, "ALLOWLIST_INVALID", "allowlist invalid"
    if not isinstance(data, dict):
        return None, "ALLOWLIST_INVALID", "allowlist invalid"
    rules = data.get("rules")
    if not isinstance(rules, list):
        return None, "ALLOWLIST_INVALID", "allowlist missing rules"
    valid = []
    for r in rules:
        if not isinstance(r, dict):
            continue
        cmd = r.get("cmd")
        max_args = r.get("maxArgs")
        if not isinstance(cmd, str) or not cmd.startswith("/"):
            continue
        if not isinstance(max_args, int) or max_args < 0:
            continue
        valid.append(r)
    return valid, "", ""

def vault_post(evt: dict):
    data = json.dumps(evt).encode("utf-8")
    req = urllib.request.Request(
        vault_url,
        data=data,
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        if r.status < 200 or r.status >= 300:
            raise RuntimeError(f"vault status {r.status}")

def denial_event(request_id, req_hash, cmd, args, cwd, timeout_ms, reason, code):
    return {
        "type": "agent.ssh.denied",
        "src": node_id,
        "ts_ms": int(time.time() * 1000),
        "data": {
            "id": request_id,
            "cmd": cmd,
            "args": args,
            "cwd": cwd,
            "timeout_ms": timeout_ms,
            "req_hash": req_hash,
            "reason": reason,
            "code": code,
        },
    }

def maybe_log_denied(evt):
    try:
        vault_post(evt)
    except Exception:
        pass

def deny(request_id, req_hash, cmd, args, cwd, timeout_ms, reason, code, exit_code=3):
    maybe_log_denied(denial_event(request_id, req_hash, cmd, args, cwd, timeout_ms, reason, code))
    out({"ok": False, "id": request_id, "error": reason, "code": code}, exit_code)

def in_allowed_target(target: str, allowed: list[str]) -> bool:
    for a in allowed:
        if target == a:
            return True
        try:
            net = ipaddress.ip_network(a, strict=False)
            ip = ipaddress.ip_address(target)
            if ip in net:
                return True
        except Exception:
            continue
    return False

def in_allowed_prefix(arg: str, prefixes: list[str]) -> bool:
    try:
        real = os.path.realpath(arg)
    except Exception:
        return False
    for p in prefixes:
        if not isinstance(p, str):
            continue
        base = os.path.realpath(p)
        if real == base or real.startswith(base + os.sep):
            return True
    return False

try:
    req = json.loads(line)
except Exception:
    out({"ok": False, "error": "invalid JSON", "code": "BAD_REQUEST"}, 2)

request_id = req.get("id")
cmd = req.get("cmd")
args = req.get("args", [])
cwd = req.get("cwd", ".")
timeout_ms = int(req.get("timeout_ms", 30000))
req_hash = sha256(line)

if not isinstance(request_id, str) or not request_id:
    out({"ok": False, "error": "id must be non-empty string", "code": "BAD_REQUEST"}, 2)
if not isinstance(cmd, str) or not cmd.startswith("/"):
    out({"ok": False, "id": request_id, "error": "cmd must be absolute path", "code": "BAD_REQUEST"}, 2)
if not isinstance(args, list) or any(not isinstance(x, str) for x in args):
    out({"ok": False, "id": request_id, "error": "args must be list of strings", "code": "BAD_REQUEST"}, 2)
if not isinstance(cwd, str):
    out({"ok": False, "id": request_id, "error": "cwd must be string", "code": "BAD_REQUEST"}, 2)

rules, load_code, load_err = load_allowlist(allowlist_path)
if rules is None:
    out({"ok": False, "id": request_id, "error": load_err, "code": load_code}, 3)

rule = None
for r in rules:
    if r.get("cmd") == cmd:
        rule = r
        break
if rule is None:
    deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "command not allowed", "NOT_ALLOWED")

if len(args) > int(rule.get("maxArgs", 0)):
    deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "too many args", "ARGS_LIMIT")

allowed_cwd = rule.get("cwd")
if isinstance(allowed_cwd, list) and allowed_cwd:
    try:
        cwd_real = os.path.realpath(cwd)
    except Exception:
        deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "cwd not allowed", "CWD_DENIED")
    cwd_ok = False
    for base in allowed_cwd:
        if not isinstance(base, str):
            continue
        base_real = os.path.realpath(base)
        if cwd_real == base_real or cwd_real.startswith(base_real + os.sep):
            cwd_ok = True
            break
    if not cwd_ok:
        deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "cwd not allowed", "CWD_DENIED")

subcommands = rule.get("subcommands", [])
if isinstance(subcommands, list) and subcommands:
    if not args or args[0] not in subcommands:
        deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "subcommand denied", "SUBCOMMAND_DENIED")

allowed_flags = [f for f in rule.get("allowedFlags", []) if isinstance(f, str)]
deny_flags = {f for f in rule.get("denyFlags", []) if isinstance(f, str)}
for idx, a in enumerate(args):
    if not a.startswith("-"):
        continue
    if a in deny_flags:
        deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "flag denied", "FLAG_DENIED")
    if allowed_flags and a not in allowed_flags:
        deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "flag not allowed", "FLAG_NOT_ALLOWED")
    # Sanity for paired flag value: ensure it exists and is not another flag when expected
    if a in ("-u", "-n", "--top-ports", "-c", "-W") and idx + 1 >= len(args):
        deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "missing flag value", "FLAG_VALUE_MISSING")

allowed_units = [u for u in rule.get("allowedUnits", []) if isinstance(u, str)]
if allowed_units and cmd.endswith("systemctl"):
    unit_args = [a for a in args if a.endswith(".service")]
    if not unit_args:
        deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "unit required", "UNIT_REQUIRED")
    for u in unit_args:
        if u not in allowed_units:
            deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "unit denied", "UNIT_DENIED")

allowed_targets = [t for t in rule.get("allowedTargets", []) if isinstance(t, str)]
if allowed_targets and (cmd.endswith("ping") or cmd.endswith("nmap")):
    targets = []
    for i, a in enumerate(args):
        if a.startswith("-"):
            continue
        if i > 0 and args[i - 1] in ("-c", "-W", "--top-ports"):
            continue
        targets.append(a)
    if not targets:
        deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "target required", "TARGET_REQUIRED")
    for target in targets:
        if not in_allowed_target(target, allowed_targets):
            deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "target denied", "TARGET_DENIED")

allowed_path_prefixes = [p for p in rule.get("allowedPathPrefixes", []) if isinstance(p, str)]
if allowed_path_prefixes:
    for i, arg in enumerate(args):
        if arg.startswith("-"):
            continue
        if i > 0 and args[i - 1] in ("-n", "--top-ports", "-c", "-W", "-u"):
            continue
        if arg.startswith("/"):
            if not in_allowed_prefix(arg, allowed_path_prefixes):
                deny(request_id, req_hash, cmd, args, cwd, timeout_ms, "path denied", "PATH_DENIED")

intent = {
    "type": "agent.ssh.intent",
    "src": node_id,
    "ts_ms": int(time.time() * 1000),
    "data": {
        "id": request_id,
        "cmd": cmd,
        "args": args,
        "cwd": cwd,
        "timeout_ms": timeout_ms,
        "req_hash": req_hash,
    },
}

try:
    vault_post(intent)
except Exception:
    out(
        {
            "ok": False,
            "id": request_id,
            "error": "vault ingest failed; refusing to execute",
            "code": "VAULT_DOWN_FAIL_CLOSED",
        },
        4,
    )

start = time.time()
try:
    p = subprocess.run(
        [cmd, *args],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout_ms / 1000,
    )
    stdout = p.stdout[:MAX_OUTPUT_BYTES].decode("utf-8", "replace")
    stderr = p.stderr[:MAX_OUTPUT_BYTES].decode("utf-8", "replace")
    ok = p.returncode == 0
    exit_code = p.returncode
except subprocess.TimeoutExpired as e:
    stdout = (e.stdout or b"")[:MAX_OUTPUT_BYTES].decode("utf-8", "replace")
    stderr = (e.stderr or b"")[:MAX_OUTPUT_BYTES].decode("utf-8", "replace")
    ok = False
    exit_code = 124

duration_ms = int((time.time() - start) * 1000)
result = {
    "type": "agent.ssh.result",
    "src": node_id,
    "ts_ms": int(time.time() * 1000),
    "data": {
        "id": request_id,
        "cmd": cmd,
        "args": args,
        "cwd": cwd,
        "ok": ok,
        "exit_code": exit_code,
        "duration_ms": duration_ms,
        "stdout_sha256": sha256(stdout),
        "stderr_sha256": sha256(stderr),
        "stdout": stdout,
        "stderr": stderr,
        "req_hash": req_hash,
    },
}

try:
    vault_post(result)
except Exception:
    pass

out({
    "ok": ok,
    "id": request_id,
    "exit_code": exit_code,
    "duration_ms": duration_ms,
    "stdout": stdout,
    "stderr": stderr,
})
PY
SH

PUB="$(cat "$PUBKEY_PATH")"
AUTH_LINE="command=\"/usr/local/bin/strangelab-ssh-guard\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding ${PUB}"
echo "$AUTH_LINE" | sudo tee /home/strangelab/.ssh/authorized_keys >/dev/null
sudo chmod 600 /home/strangelab/.ssh/authorized_keys
sudo chown strangelab:strangelab /home/strangelab/.ssh/authorized_keys

sudo tee /etc/default/strangelab-ssh-guard >/dev/null <<ENV
VAULT_INGEST_URL=${VAULT_INGEST_URL}
NODE_ID=${NODE_ID}
ALLOWLIST=/opt/strangelab/allowlist.json
ENV

echo "ssh guard installed on $(hostname -s)"
