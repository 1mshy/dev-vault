import XCTest
import SecretsVaultCore

final class VaultNamingTests: XCTestCase {

    func testVaultNameReplacesPathSeparators() {
        XCTAssertEqual(VaultNaming.sanitizedVaultName("a/b:c\\d"), "a-b-c-d")
    }

    func testVaultNameTrimsWhitespaceAndLeadingDots() {
        XCTAssertEqual(VaultNaming.sanitizedVaultName("  ..hidden  "), "hidden")
        XCTAssertEqual(VaultNaming.sanitizedVaultName("keep.dots.inside"), "keep.dots.inside")
    }

    func testVaultNameIsCappedAt60Characters() {
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(VaultNaming.sanitizedVaultName(long).count, 60)
    }

    func testVaultNameCanBeEmpty() {
        XCTAssertEqual(VaultNaming.sanitizedVaultName("..."), "")
        XCTAssertEqual(VaultNaming.sanitizedVaultName("   "), "")
        XCTAssertEqual(VaultNaming.sanitizedVaultName(""), "")
    }

    func testFilenameNeverEmpty() {
        XCTAssertEqual(VaultNaming.sanitizedFilename(""), "Untitled")
        XCTAssertEqual(VaultNaming.sanitizedFilename(" .. "), "Untitled")
        XCTAssertEqual(VaultNaming.sanitizedFilename("a/b"), "a-b")
    }

    func testFilenameIsCappedAt120Characters() {
        let long = String(repeating: "y", count: 200)
        XCTAssertEqual(VaultNaming.sanitizedFilename(long).count, 120)
    }

    func testUniqueNameIsCaseInsensitiveAndCounts() {
        var used: Set<String> = []
        XCTAssertEqual(VaultNaming.uniqueName("Notes", used: &used), "Notes")
        XCTAssertEqual(VaultNaming.uniqueName("notes", used: &used), "notes 2")
        XCTAssertEqual(VaultNaming.uniqueName("NOTES", used: &used), "NOTES 3")
        XCTAssertEqual(VaultNaming.uniqueName("Other", used: &used), "Other")
        XCTAssertEqual(used, ["notes", "notes 2", "notes 3", "other"])
    }
}
