# Orchestrator Status

`services/orchestrator` is intentionally reserved and is not part of the active runtime in this repository.

## Current Status

- No process is launched from this directory by default tooling.
- No runtime wiring currently exists from `cli/sods`, `apps/dev-station`, or `ops/strangelab-control-plane`.
- This repo currently has no active integration here for LiveKit, AgentPortal, or Codegatchi paths.

## Scope Boundary

Use this folder only for explicit future design/prototyping work. The active runtime path today is:

- spine + APIs: `cli/sods`
- operator UI: `apps/dev-station`
- fleet/control-plane ops: `ops/strangelab-control-plane`
