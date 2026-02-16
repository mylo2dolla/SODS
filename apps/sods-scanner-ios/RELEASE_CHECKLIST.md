# SODS Scanner iOS Release Checklist

## App Store Connect Setup

1. Create subscription group: `SODS Scanner Pro`.
2. Create subscription product IDs:
   - `com.strangelab.sods.scanner.pro.monthly`
   - `com.strangelab.sods.scanner.pro.yearly` with a 7-day introductory free trial.
3. Fill localized metadata, screenshots, and review notes.
4. Add final public Privacy Policy and Terms URLs in App Store Connect.
5. Verify pricing and availability regions.

## Pre-Release Validation

1. Run `scripts/build-simulator-no-sign.sh`.
2. Run `scripts/validate-signing.sh` (or `DEVELOPMENT_TEAM_OVERRIDE=<TEAM_ID> scripts/validate-signing.sh`).
3. Run `scripts/archive-release.sh` once valid team/profiles are configured (or with `DEVELOPMENT_TEAM_OVERRIDE=<TEAM_ID>`).
4. Run `scripts/export-ipa.sh` to produce an App Store IPA export (`DEVELOPMENT_TEAM_OVERRIDE=<TEAM_ID> scripts/export-ipa.sh` if needed).
5. In Xcode, set the run scheme StoreKit configuration to `SODSScanneriOS/Resources/SODSScanner.storekit` for local purchase testing.
6. Upload build to TestFlight and verify:
   - Free tier feature gating.
   - Monthly and yearly purchase flow.
   - 7-day yearly trial behavior.
   - Restore purchases.
   - Device scan behavior (BLE + LAN) and dynamic device info rendering.

## Final Submission

1. Confirm legal text in app and public policy URLs in store metadata are aligned.
2. Submit for review.
