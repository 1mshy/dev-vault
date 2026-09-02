import XCTest
import SecretsVaultCore

final class AppVersionTests: XCTestCase {

    func testComparesNumericallyNotLexically() {
        XCTAssertTrue(AppVersion.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(AppVersion.isNewer("1.0.9", than: "1.0.10"))
    }

    func testEqualIsNotNewer() {
        XCTAssertFalse(AppVersion.isNewer("1.0.5", than: "1.0.5"))
        XCTAssertFalse(AppVersion.isNewer("1.0", than: "1.0.0"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(AppVersion.isNewer("1.1", than: "1.0.5"))
        XCTAssertTrue(AppVersion.isNewer("1.0.0.1", than: "1.0"))
    }

    func testMajorAndMinorTakePrecedence() {
        XCTAssertTrue(AppVersion.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertTrue(AppVersion.isNewer("1.1.0", than: "1.0.99"))
    }

    func testLeadingVAndSuffixAreIgnored() {
        XCTAssertTrue(AppVersion.isNewer("v1.0.5", than: "1.0.4"))
        XCTAssertTrue(AppVersion.isNewer("1.0.5", than: "V1.0.4"))
        XCTAssertFalse(AppVersion.isNewer("1.0.5-dev", than: "1.0.5"))
    }

    func testGarbageComponentsAreZero() {
        XCTAssertFalse(AppVersion.isNewer("x.y", than: "0.0"))
        XCTAssertTrue(AppVersion.isNewer("1.x", than: "0.9"))
    }
}
