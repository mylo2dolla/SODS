# SODS Federation Contract (LiveKit Replacement)

## Scope
This document defines the active control-plane contract for SODS after LiveKit removal.

## Canonical Runtime Topology
- Ingress host: `aux` (`strangelab-god-gateway`, `strangelab-token`, `strangelab-ops-feed`)
- Federation runtime host: `mac16` (`Codegatchi daemon/runner`)
- Transport bridge: `aux` local tunnel to `mac16` gateway (`127.0.0.1:9777`)

## Pinned Canonical Refs (v1.1.2)
- `codegatchi`: `ssh://pi@vault/home/pi/git/codegatchi.git` @ `codegatchi-v1.1.2-release-hygiene`
- `AgentPortal`: `ssh://pi@vault/home/pi/git/AgentPortal.git` @ `agentportal-v1.1.2-release-hygiene`
- `LvlUpKit.package`: `ssh://pi@vault/home/pi/git/LvlUpKit.package.git` @ `lvlupkit-v1.1.2-canonical`
- `Newproject`: `ssh://pi@vault/home/pi/git/Newproject.git` @ `newproject-v1.1.2-submodule-fixed`

## Compatibility Endpoints (unchanged externally)
- `POST /god` on `aux:8099`
- `GET /health` on `aux:8099`
- `POST /token` on `aux:9123`
- `GET /health` on `aux:9123`

## Federation Dispatch Contract
- Gateway endpoint: `POST /v1/gateway` on Codegatchi.
- Envelope format: `CodegatchiGatewayEnvelope` (`v=1`, `msgId`, `tsMs`, `nonce`, `traceId`, `op`, `payload`).
- Dispatch ops used by SODS compatibility bridge:
  - `dispatch.intent`
  - `dispatch.tool` (when action map explicitly requests it)
  - `sync.full` (agent/tool discovery)
- Health probe used by bridge:
  - `GET /v1/health`

## Action Mapping Source Of Truth
- File: `/opt/strangelab/federation-targets.json`
- Repo canonical: `/Users/letsdev/SODS-main/ops/strangelab-control-plane/config/federation-targets.json`
- Every allowlisted SODS action must exist in `actions` map.
- Validation script:
  - `/Users/letsdev/SODS-main/tools/verify-federation-contract.sh`

## Security Requirements
- Codegatchi keychain service: `com.dev.codegatchi.gateway`
- Token key: `codegatchi.gateway.token.v1`
- Raw tokens must never be printed in logs or exported diagnostics.
- Default remote-peer policy must remain disabled unless explicitly enabled:
  - `CODEGATCHI_ALLOW_REMOTE=0`

## Operational Defaults
- `agentportal.federation.enabled=false` by default.
- Bridge must run on `aux` regardless of federation runtime host.
- If `docs/CANONICAL_REPOS.md` in Newproject disagrees with this contract, use the pinned refs above.
