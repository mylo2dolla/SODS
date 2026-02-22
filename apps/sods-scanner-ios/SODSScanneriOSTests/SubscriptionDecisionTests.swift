import XCTest
@testable import SODSScanneriOS

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

    func testCachedGraceEntitlementExpiresAfterWindow() {
        let now = Date(timeIntervalSince1970: 1_706_700_000)
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
