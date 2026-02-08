# StrangeLab Control Plane

## Locked Network Constants

- `pi-aux`: `192.168.8.114`
- `pi-logger` ethernet: `192.168.8.160`
- `pi-logger` wifi (optional): `192.168.8.169`
- `vault-ingest`: `http://192.168.8.160:8088/v1/ingest`
- `livekit`: `ws://192.168.8.114:7880`
- `token`: `http://192.168.8.114:9123/token`
- `god gateway`: `http://192.168.8.114:8099/god`
- room: `strangelab`
- keypair: `devkey/secret`

## Invariants

- Vault-first, fail-closed.
- No raw shell.
- Allowlist-only command execution.
- Capabilities deny by default.
- Every action explainable from Vault events.

## Services

### pi-aux

- LiveKit (`docker compose`)
- `strangelab-token.service`
- `strangelab-god-gateway.service`
- `strangelab-exec-agent@pi-aux.service`
- `strangelab-ops-feed.service` (`:9101`)

### pi-logger

- `strangelab-vault-ingest.service`
- `strangelab-exec-agent@pi-logger.service`

### mac1 / mac2

- LaunchDaemon:
  - `com.strangelab.exec-agent.mac1`
  - `com.strangelab.exec-agent.mac2`

## Action Routing

`god-gateway` receives `god.button`, validates/rate-limits/dedupes, logs `router.*`, then routes:

- `panic.*` -> `ops.panic`
- `snapshot.*` -> `ops.snapshot`
- `maint.*` -> `ops.maint`
- `scan.*` -> `ops.scan`
- `build.*` -> `ops.build`
- `ritual.*` -> `ops.ritual`

Legacy compatibility:

- `{ "op": "panic" }` -> `panic.freeze.agents`
- `{ "op": "whoami" }` -> `ritual.rollcall`

## Starter Actions

- `snapshot.now`
- `maint.status.service`
- `maint.restart.service`
- `panic.freeze.agents`
- `ritual.rollcall`

Dry-run is supported by setting `dry_run: true` (request payload or args). Dry-run logs intent/result and executes nothing.

## Capability Matrix

Each host loads `/opt/strangelab/capabilities.json` at startup and on `SIGHUP`.

- Missing/invalid file: all non-snapshot actions disabled.
- Capability denial logs `agent.capability.denied`.

Templates:

- `services/capabilities/mac1.json`
- `services/capabilities/mac2.json`
- `services/capabilities/pi-aux.json`
- `services/capabilities/pi-logger.json`

## SSH Roving Agent (Restricted)

### Target install (Linux)

```bash
bash scripts/install-ssh-guard-linux.sh ~/.ssh/strangelab_controller.pub pi-aux
bash scripts/install-ssh-guard-linux.sh ~/.ssh/strangelab_controller.pub pi-logger
```

### Target install (macOS)

```bash
bash scripts/install-ssh-guard-macos.sh ~/.ssh/strangelab_controller.pub mac1
bash scripts/install-ssh-guard-macos.sh ~/.ssh/strangelab_controller.pub mac2
```

### Controller setup (mac1)

```bash
bash scripts/setup-ssh-controller.sh 192.168.8.214
```

Creates:

- `~/.ssh/strangelab_controller` keypair
- host aliases in `~/.ssh/config`
- `/usr/local/bin/sl-ssh`

Usage:

```bash
sl-ssh strangelab-pi-aux t1 /usr/bin/uptime
sl-ssh strangelab-pi-logger t2 /bin/df -h
```

Guard behavior:

- Loads `/opt/strangelab/allowlist.json`.
- Denies all if allowlist missing/invalid.
- Logs `agent.ssh.denied` on refusal.
- Logs `agent.ssh.intent` before execution.
- Fails closed if Vault ingest fails.
- Logs `agent.ssh.result` after execution.

Allowlist templates:

- `services/allowlist/mac1.json`
- `services/allowlist/mac2.json`
- `services/allowlist/pi-aux.json`
- `services/allowlist/pi-logger.json`

## Install Flow

### pi-aux

```bash
bash scripts/install-pi-aux.sh
```

This now also installs desktop control-surface launchers:

- `/opt/strangelab/bin/sl-god`
- `/opt/strangelab/bin/sl-panic`
- `/opt/strangelab/bin/sl-maint-now`
- `/opt/strangelab/bin/sl-scan-lan-now`
- `/opt/strangelab/bin/sl-status`

### pi-logger

```bash
bash scripts/install-vault-ingest.sh
bash scripts/install-pi-logger.sh
```

### mac1/mac2

```bash
bash scripts/install-mac-agent.sh mac1
bash scripts/install-mac-agent.sh mac2
```

## Health Checks

```bash
curl -sS http://192.168.8.114:9123/health
curl -sS http://192.168.8.114:8099/health
curl -sS http://192.168.8.114:9101/health
curl -sS http://192.168.8.160:8088/health
```

## God Button Test

```bash
curl -sS -X POST http://192.168.8.114:8099/god \
  -H 'content-type: application/json' \
  -d '{"action":"ritual.rollcall","scope":"all","reason":"operator test","args":{"dry_run":true}}'
```

## Verification Pack

Canonical verification runbook:

- `VERIFY.md`

Automation scripts:

- `tools/verify-network.sh`
- `tools/verify-vault.sh`
- `tools/verify-control-plane.sh`
- `tools/verify-ssh-guard.sh`
- `tools/verify-ui-data.sh`
- `tools/verify-all.sh`
- `tools/verify.sh` (runs all of the above)

## BLE Identity Stabilization

BLE normalization and canonical identity registry:

- module: `services/ble/identity-core.mjs`
- docs: `BLE_IDENTITY.md`
- rebuild tool: `tools/ble-rebuild-registry.mjs`

`vault-ingest` now derives and appends:

- `ble.device.seen`
- `ble.device.merged`

from incoming `ble.observation` events, persisted via registry DB:

- `/var/lib/strangelab/registry.sqlite`
