# Full-Stack Audit Rerun Report (2026-02-17)

## Scope
- Workspace: `/Users/letsdev/SODS-main`
- Mode: collect-all-findings, current dirty working tree
- Runs:
  - Run #1 logs: `/tmp/sods-audit-20260217-055739`
  - Run #2 logs: `/tmp/sods-audit-20260217-060616-rerun2`

## Baseline
- HEAD at execution: `562d21b harden runtime artifact hygiene + vaultsync`
- Working tree state: dirty by design for this audit run

## Command Matrix
| Phase | Gate | Run #1 | Run #2 |
|---|---|---|---|
| 0 | Baseline snapshot (`git log`, `git status`, `_env.sh`) | PASS | PASS |
| 1 | `./tools/audit-repo.sh` | PASS | PASS |
| 1 | `./tools/audit-tools.sh` | PASS | PASS |
| 1 | `rg -n "projectoverveiw" .` | PASS (no matches) | PASS (no matches) |
| 1 | Runtime artifact tracked-path scan | PASS (no tracked matches) | PASS (no tracked matches) |
| 2 | `cd cli/sods && npm test` | PASS | PASS |
| 2 | `cd apps/scanner-spectrum-core && swift test` | PASS | PASS |
| 2 | `cd apps/sods-scanner-ios && swift test` | PASS | PASS |
| 2 | iOS XCTest (`xcodebuild ... SODSScanneriOS ... test`) | PASS | PASS |
| 2 | Dev Station compile (`xcodebuild ... DevStation ... build`) | PASS | PASS |
| 2 | `./tools/verify-ui-data.sh` | PASS | PASS |
| 3 | `./tools/verify-network.sh` | PASS | PASS |
| 3 | `./tools/verify-vault.sh` | PASS | PASS |
| 3 | `./tools/verify-control-plane.sh` | PASS | PASS |
| 3 | `./tools/verify-all.sh` | PASS | PASS |
| 4 | `./tools/smoke-station.sh` | PASS | PASS |
| 4 | `./tools/smoke.sh` | PASS | PASS |
| 4 | `SODS_ROOT=... DRY_RUN=1 ./tools/vaultsync.sh outbox` | PASS | PASS |
| 4 | `git check-ignore -v ...` | PASS | PASS |

## Findings
### P0 (Blockers)
- None.

### P1 (Major Runtime/Fleet)
- None.

### P2 (Consistency/Hygiene)
- None.

### P3 (Informational)
- Optional sibling package not present:
  - `verify-ui-data` and smoke package visualizer sync checks report skip for missing `/Users/letsdev/LvlUpKit.package`.
- Non-fatal build warnings from App Intents metadata extraction in Xcode logs.
- Prior smoke output included stale `last_error` strings from recovered polling failures (addressed in this branch by clearing station ingest error on successful poll).

## Delta vs Prior Failed Audit Cycle
- Fixed and now stable across two consecutive runs:
  - `verify-control-plane` god action and ops-feed evidence checks pass.
  - `verify-all` integrated gate passes.
- No new regressions surfaced between run #1 and run #2.

## Notes
- This report is audit-only and records outcomes against the current dirty working tree without requiring a clean precondition.
