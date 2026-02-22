import XCTest
@testable import SODSScannerMonetizationLogic

final class SubscriptionDecisionTests: XCTestCase {
    func testNormalizeEmailTrimsAndLowercases() {
        XCTAssertEqual(
            SubscriptionDecision.normalizeEmail("  LetsDev23@iCloud.Com  "),
            "letsdev23@icloud.com"
        )
    }

    func testDebugEntitlementUsesAllowlistBeforeOverride() {
        let now = Date(timeIntervalSince1970: 1_706_000_000)
        let allowlist: Set<String> = ["letsdev23@icloud.com"]

        let entitlement = SubscriptionDecision.debugEntitlement(
            now: now,
            normalizedEmail: "letsdev23@icloud.com",
            allowlist: allowlist,
            debugOverrideEnabled: false
        )

        XCTAssertEqual(entitlement?.source, .debugAdminAllowlist)
        XCTAssertEqual(entitlement?.verifiedAt, now)
        XCTAssertTrue(entitlement?.isPro == true)
    }

    func testDebugEntitlementFallsBackToOverride() {
        let now = Date(timeIntervalSince1970: 1_706_000_000)
        let entitlement = SubscriptionDecision.debugEntitlement(
            now: now,
            normalizedEmail: "not-allowed@example.com",
            allowlist: [],
            debugOverrideEnabled: true
        )

        XCTAssertEqual(entitlement?.source, .debugOverride)
        XCTAssertTrue(entitlement?.isPro == true)
    }

    func testCachedGraceEntitlementWithinWindow() {
        let now = Date(timeIntervalSince1970: 1_706_086_400) // +1 day
        let verifiedAt = Date(timeIntervalSince1970: 1_706_000_000)
        let expiresAt = Date(timeIntervalSince1970: 1_706_172_800)

        let entitlement = SubscriptionDecision.cachedGraceEntitlement(
            now: now,
            lastVerifiedAt: verifiedAt,
            expiresAt: expiresAt,
            graceWindow: 7 * 24 * 60 * 60
        )

        XCTAssertEqual(entitlement?.source, .cachedGrace)
        XCTAssertEqual(entitlement?.verifiedAt, verifiedAt)
        XCTAssertEqual(entitlement?.expiresAt, expiresAt)
        XCTAssertTrue(entitlement?.isPro == true)
    }

    func testCachedGraceEntitlementExpiresAfterWindow() {
        let now = Date(timeIntervalSince1970: 1_706_700_000) // > 7 day grace
        let verifiedAt = Date(timeIntervalSince1970: 1_706_000_000)

        let entitlement = SubscriptionDecision.cachedGraceEntitlement(
            now: now,
            lastVerifiedAt: verifiedAt,
            expiresAt: nil,
            graceWindow: 7 * 24 * 60 * 60
        )

        XCTAssertNil(entitlement)
    }
}
