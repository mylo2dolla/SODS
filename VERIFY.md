# StrangeLab Front-to-Back Verification

This is the canonical runbook for verifying sections **A–K** end-to-end.

Locked endpoints:

- `pi-aux`: `192.168.8.114`
- `pi-logger`: `192.168.8.160`
- `LiveKit`: `ws://192.168.8.114:7880`
- `Token`: `http://192.168.8.114:9123/token`
- `God gateway`: `http://192.168.8.114:8099/god`
- `Vault ingest`: `http://192.168.8.160:8088/v1/ingest`

Hard rule:

- If Vault ingest fails, execution actions must fail closed.

## Quick Run (Automated)

From `SODS` repo root:

```bash
./tools/verify-all.sh
```

`verify-all` runs the complete front-to-back set (network, vault, control-plane, ops-feed, request trace/dedupe, ssh guard, and UI data rules) and exits nonzero on any failure.

Optional reboot persistence check (vault section B4):

```bash
WITH_REBOOT=1 ./tools/verify-vault.sh
```

## A) Network & Host Identity

```bash
./tools/verify-network.sh
```

Expected:

- ping to `192.168.8.114` passes.
- ping to `192.168.8.160` passes.
- `hostname` on pi-aux is `pi-aux`.
- `hostname` on pi-logger is `pi-logger`.

## B) Vault (pi-logger) First

```bash
./tools/verify-vault.sh
```

Expected:

- Vault service active (`strangelab-vault` or `strangelab-vault-ingest` or `vault`).
- Port `8088` listening.
- Local ingest POST passes.
- Remote ingest POST passes.
- With reboot check enabled, service recovers after reboot.

## C) Control Plane (pi-aux)

```bash
./tools/verify-control-plane.sh
```

Expected:

- LiveKit container up and `:7880` listening.
- `strangelab-token` active and token endpoint returns token JSON.
- `strangelab-god-gateway` active and `/god` accepts structured action payloads.

## C2) Ops Feed Read API

```bash
curl -sS http://192.168.8.114:9101/health
curl -sS 'http://192.168.8.114:9101/events?limit=50&typePrefix=agent.'
curl -sS 'http://192.168.8.114:9101/trace?request_id=<id>&limit=200'
curl -sS 'http://192.168.8.114:9101/nodes?window_s=120'
```

Expected:

- `/health` returns `{"ok":true,...}`.
- `/events` is bounded (max 500).
- `/trace` returns request-correlated events.
- `/nodes` derives recent node presence.

## D) Exec Agents (all hosts)

```bash
./tools/verify-control-plane.sh
```

Expected:

- `strangelab-exec-agent@pi-aux` (or fallback unit) active.
- `strangelab-exec-agent@pi-logger` (or fallback unit) active.
- launchd entry exists for mac agent on active Mac (`mac1` or `mac2`).

## E) Fail-Closed Proof

Manual exact sequence:

```bash
ssh pi@192.168.8.160 'sudo systemctl stop strangelab-vault-ingest || sudo systemctl stop strangelab-vault || sudo systemctl stop vault'
curl -sS -X POST http://192.168.8.114:8099/god -H 'content-type: application/json' -d '{"op":"whoami"}'
ssh pi@192.168.8.160 'sudo systemctl start strangelab-vault-ingest || sudo systemctl start strangelab-vault || sudo systemctl start vault'
curl -sS -X POST http://192.168.8.160:8088/v1/ingest -H 'content-type: application/json' -d '{"type":"vault.test","src":"verify","ts_ms":0,"data":{"ok":true}}'
```

Expected:

- While Vault is stopped, execution attempts are refused.
- After restart, ingest and actions recover.

Non-destructive gate check is included in `verify-all.sh` by issuing a dry-run style action and confirming trace visibility.

## F) God Button End-to-End

```bash
curl -sS -X POST http://192.168.8.114:8099/god \
  -H 'content-type: application/json' \
  -d '{"action":"snapshot.now","scope":"tier1","target":null,"request_id":"verify-sn-1","reason":"verify","ts_ms":0,"args":{}}'

curl -sS -X POST http://192.168.8.114:8099/god \
  -H 'content-type: application/json' \
  -d '{"action":"snapshot.now","scope":"tier1","target":null,"request_id":"verify-sn-1","reason":"duplicate","ts_ms":0,"args":{}}'
```

Expected:

- first request routes and logs intent/result.
- duplicate `request_id` is denied.

## G) SSH Roving Guard

```bash
./tools/verify-ssh-guard.sh
```

Expected:

- controller key exists.
- `sl-ssh` works on `pi-aux`, `pi-logger`, `mac2`.
- deny test `/bin/bash` returns `NOT_ALLOWED`.

## H) Allowlist Enforcement

Automated coverage is in `verify-ssh-guard.sh` (allowlist presence + deny behavior).

Optional hard fail-safe manual check:

```bash
ssh pi@192.168.8.114 'sudo mv /opt/strangelab/allowlist.json /opt/strangelab/allowlist.json.bak'
echo '{"id":"allow-missing","cmd":"/usr/bin/uptime","args":[],"cwd":".","timeout_ms":1000}' | ssh strangelab-pi-aux
ssh pi@192.168.8.114 'sudo mv /opt/strangelab/allowlist.json.bak /opt/strangelab/allowlist.json'
```

Expected:

- command denied when allowlist file is missing.

## I) Capability Matrix Enforcement

Check file exists:

```bash
ssh pi@192.168.8.114 'test -f /opt/strangelab/capabilities.json'
ssh pi@192.168.8.160 'test -f /opt/strangelab/capabilities.json'
```

Optional invalid-file fail-safe test:

```bash
ssh pi@192.168.8.114 "sudo cp /opt/strangelab/capabilities.json /opt/strangelab/capabilities.json.bak && echo '{\"invalid\":true}' | sudo tee /opt/strangelab/capabilities.json >/dev/null && sudo systemctl restart strangelab-exec-agent@pi-aux"
curl -sS -X POST http://192.168.8.114:8099/god -H 'content-type: application/json' -d '{"action":"maint.status.service","scope":"node","target":"exec-pi-aux","request_id":"cap-deny-1","reason":"verify","ts_ms":0,"args":{"service":"strangelab-token"}}'
ssh pi@192.168.8.114 "sudo mv /opt/strangelab/capabilities.json.bak /opt/strangelab/capabilities.json && sudo systemctl restart strangelab-exec-agent@pi-aux"
```

Expected:

- non-snapshot action denied while capabilities file is invalid.

## J) Spectrum Diagram Upgrade

```bash
./tools/verify-ui-data.sh
```

Expected:

- directional edge pulse implementation present.
- fixed type-color mapping (`CONTROL/EVENT/EVIDENCE/MEDIA/MGMT`) present.
- transport styles present (HTTP, LiveKit, SSH, BLE, Wi-Fi passive, Serial).
- edge hover tooltip and click trace panel present.
- visualizer package/app sync check passes.
- dynamic-data runtime compliance check passes.

## K) Done Criteria

All sections A–J pass and fail-closed behavior is proven in section E.

## BLE Identity Repair

Rebuild BLE canonical identity registry from Vault observations:

```bash
node ./tools/ble-rebuild-registry.mjs --hours 24
```

Expected output includes:

- total observations replayed
- devices created
- merges performed
- top unstable random-address sources
