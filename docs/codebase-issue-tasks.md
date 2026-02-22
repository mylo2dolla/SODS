# Codebase issue task proposals

## 1) Typo fix task
**Task:** Rename the misspelled project overview filename to `projectoverview.txt` (or migrate its content into a canonical markdown doc in `docs/`) and update any scripts/docs that reference the old path.

**Why:** The file name contains a spelling typo (`overveiw`), which makes search/discovery harder and propagates inconsistent naming in the repo.

**Acceptance criteria:**
- File is renamed to a correctly spelled path.
- Any references to the misspelled filename are updated.
- Repo search returns no references to the misspelled filename.

## 2) Bug fix task
**Task:** Fix `/metrics` so `frames_out` reports actual emitted frames instead of reusing event counters.

**Why:** In `SODSServer`, `/metrics` currently sets `frames_out` to `counters.events_out`, which tracks emitted canonical events from ingestion, not rendered/emitted frames.

**Acceptance criteria:**
- Add a dedicated frame counter in `SODSServer` (incremented when frames are emitted in `emitFrames()`).
- `/metrics` exposes this real frame counter as `frames_out`.
- Add/adjust tests to verify `frames_out` changes only when frames are emitted.

## 3) Documentation discrepancy task
**Task:** Reconcile CLI default logger documentation with actual runtime defaults.

**Why:** `README.md` says defaults for `whereis/open/tail` use `http://pi-logger.local:8088`, but `cli.ts` derives default logger URL from environment and falls back to `http://192.168.8.114:9101` via `defaultPiLoggerList`.

**Acceptance criteria:**
- Decide canonical default(s) and document them consistently.
- Update `README.md` and `cli.ts` usage/help text to match.
- Add a small check (or snapshot-style test) to keep documented defaults aligned with CLI help output.

## 4) Test improvement task
**Task:** Add automated tests for ingest de-duplication and endpoint fallback behavior.

**Why:** `Ingestor` has non-trivial logic for de-duplicating by numeric/string IDs (`filterFresh`) and for falling back between `/v1/events` and `/events` (`fetchEventsBody`), but `cli/sods/package.json` has no test script today.

**Acceptance criteria:**
- Introduce a `test` script in `cli/sods/package.json`.
- Add tests that cover:
  - numeric-id dedupe progression (`lastSeenNumericId`),
  - string-id dedupe window behavior (`seenSet`/`seenMax`),
  - endpoint fallback (`/v1/events` then `/events`) and path memorization per base URL.
- Tests run in CI/local with a single documented command.
