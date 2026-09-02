import XCTest
import SecretsVaultCore

final class VaultDataTests: XCTestCase {

    private func doc(_ title: String, in folder: UUID? = nil, content: String = "",
                     deletedAt: Date? = nil) -> VaultDocument {
        VaultDocument(title: title, content: content, folderID: folder, deletedAt: deletedAt)
    }

    // MARK: Starter

    func testStarterHasWelcomeDocumentAndFolders() {
        let data = VaultData.starter()
        XCTAssertEqual(data.folders.map(\.name), ["Passwords", "Dev Commands"])
        XCTAssertEqual(data.documents.count, 1)
        XCTAssertEqual(data.documents.first?.title, "Welcome")
        XCTAssertNil(data.documents.first?.folderID)
        XCTAssertNil(data.documents.first?.deletedAt)
    }

    // MARK: Queries

    func testDocumentsInFolderExcludesDeletedAndSortsCaseInsensitively() {
        let folder = VaultFolder(name: "F")
        let data = VaultData(folders: [folder], documents: [
            doc("beta", in: folder.id),
            doc("Alpha", in: folder.id),
            doc("gone", in: folder.id, deletedAt: Date()),
            doc("root"),
        ])
        XCTAssertEqual(data.documents(in: folder.id).map(\.title), ["Alpha", "beta"])
        XCTAssertEqual(data.documents(in: nil).map(\.title), ["root"])
    }

    func testDeletedDocumentsNewestFirst() {
        let old = doc("old", deletedAt: Date(timeIntervalSince1970: 1_000))
        let new = doc("new", deletedAt: Date(timeIntervalSince1970: 2_000))
        let data = VaultData(documents: [old, doc("live"), new])
        XCTAssertEqual(data.deletedDocuments.map(\.title), ["new", "old"])
    }

    func testSearchMatchesTitleOrContentCaseInsensitively() {
        let data = VaultData(documents: [
            doc("GitHub token", content: "ghp_xxx"),
            doc("Router", content: "admin password: Hunter2"),
            doc("Deleted", content: "hunter2", deletedAt: Date()),
            doc("Unrelated", content: "nothing"),
        ])
        XCTAssertEqual(data.searchResults("hunter2").map(\.title), ["Router"])
        XCTAssertEqual(data.searchResults("GITHUB").map(\.title), ["GitHub token"])
        XCTAssertEqual(data.searchResults("   ").map(\.title), [])
        XCTAssertEqual(data.searchResults("").map(\.title), [])
    }

    func testDocumentLookup() {
        let d = doc("x")
        let data = VaultData(documents: [d])
        XCTAssertEqual(data.document(d.id)?.title, "x")
        XCTAssertNil(data.document(UUID()))
    }

    // MARK: Document lifecycle

    func testAddDocumentAppendsUntitledInFolder() {
        let folder = VaultFolder(name: "F")
        var data = VaultData(folders: [folder])
        let added = data.addDocument(in: folder.id)
        XCTAssertEqual(added.title, "")
        XCTAssertEqual(added.folderID, folder.id)
        XCTAssertEqual(data.documents.map(\.id), [added.id])
    }

    func testSoftDeleteMovesToRecentlyDeleted() {
        let d = doc("x")
        var data = VaultData(documents: [d])
        let when = Date(timeIntervalSince1970: 5_000)
        XCTAssertTrue(data.softDelete(d.id, at: when))
        XCTAssertEqual(data.document(d.id)?.deletedAt, when)
        XCTAssertEqual(data.documents(in: nil), [])
        XCTAssertEqual(data.deletedDocuments.map(\.id), [d.id])
    }

    func testSoftDeleteUnknownIDIsRejected() {
        var data = VaultData(documents: [doc("x")])
        XCTAssertFalse(data.softDelete(UUID()))
        XCTAssertEqual(data.deletedDocuments, [])
    }

    func testRestoreClearsDeletedAtAndKeepsFolder() {
        let folder = VaultFolder(name: "F")
        let d = doc("x", in: folder.id, deletedAt: Date())
        var data = VaultData(folders: [folder], documents: [d])
        XCTAssertTrue(data.restore(d.id))
        XCTAssertNil(data.document(d.id)?.deletedAt)
        XCTAssertEqual(data.document(d.id)?.folderID, folder.id)
        XCTAssertFalse(data.restore(UUID()))
    }

    func testRestoreIntoMissingFolderLandsInRoot() {
        let d = doc("x", in: UUID(), deletedAt: Date())
        var data = VaultData(documents: [d])
        XCTAssertTrue(data.restore(d.id))
        XCTAssertNil(data.document(d.id)?.folderID)
        XCTAssertEqual(data.documents(in: nil).map(\.id), [d.id])
    }

    func testPurgeRemovesPermanently() {
        let d = doc("x", deletedAt: Date())
        let keep = doc("keep")
        var data = VaultData(documents: [d, keep])
        data.purge(d.id)
        XCTAssertEqual(data.documents.map(\.id), [keep.id])
    }

    func testEmptyRecentlyDeletedLeavesLiveDocuments() {
        var data = VaultData(documents: [
            doc("a", deletedAt: Date()), doc("live"), doc("b", deletedAt: Date()),
        ])
        data.emptyRecentlyDeleted()
        XCTAssertEqual(data.documents.map(\.title), ["live"])
    }

    func testPurgeExpiredDeletedRespectsRetention() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let day: TimeInterval = 86_400
        var data = VaultData(documents: [
            doc("expired", deletedAt: now.addingTimeInterval(-31 * day)),
            doc("fresh", deletedAt: now.addingTimeInterval(-29 * day)),
            doc("live"),
        ])
        XCTAssertEqual(data.purgeExpiredDeleted(retentionDays: 30, now: now), 1)
        XCTAssertEqual(data.documents.map(\.title), ["fresh", "live"])
        XCTAssertEqual(data.purgeExpiredDeleted(retentionDays: 30, now: now), 0)
    }

    func testMoveDocument() {
        let folder = VaultFolder(name: "F")
        let d = doc("x")
        var data = VaultData(folders: [folder], documents: [d])
        XCTAssertTrue(data.move(d.id, to: folder.id))
        XCTAssertEqual(data.document(d.id)?.folderID, folder.id)
        XCTAssertTrue(data.move(d.id, to: nil))
        XCTAssertNil(data.document(d.id)?.folderID)
        XCTAssertFalse(data.move(UUID(), to: nil))
    }

    // MARK: Folders

    func testAddFolderTrimsAndRejectsBlank() {
        var data = VaultData()
        XCTAssertNil(data.addFolder(named: "   "))
        XCTAssertEqual(data.addFolder(named: "  Work ")?.name, "Work")
        XCTAssertEqual(data.folders.map(\.name), ["Work"])
    }

    func testRenameFolderTrimsAndRejectsBlankOrUnknown() {
        let folder = VaultFolder(name: "Old")
        var data = VaultData(folders: [folder])
        XCTAssertFalse(data.renameFolder(folder.id, to: " "))
        XCTAssertFalse(data.renameFolder(UUID(), to: "New"))
        XCTAssertTrue(data.renameFolder(folder.id, to: " New "))
        XCTAssertEqual(data.folders.first?.name, "New")
    }

    func testDeleteFolderMovesAllItsDocumentsToRoot() {
        let folder = VaultFolder(name: "F")
        let other = VaultFolder(name: "Other")
        let live = doc("live", in: folder.id)
        let deleted = doc("deleted", in: folder.id, deletedAt: Date())
        let elsewhere = doc("elsewhere", in: other.id)
        var data = VaultData(folders: [folder, other], documents: [live, deleted, elsewhere])
        data.deleteFolder(folder.id)
        XCTAssertEqual(data.folders.map(\.id), [other.id])
        XCTAssertNil(data.document(live.id)?.folderID)
        XCTAssertNil(data.document(deleted.id)?.folderID)
        XCTAssertNotNil(data.document(deleted.id)?.deletedAt)
        XCTAssertEqual(data.document(elsewhere.id)?.folderID, other.id)
    }

    // MARK: On-disk compatibility

    func testDocumentJSONRoundTripPreservesEveryField() throws {
        let folder = UUID()
        let original = VaultDocument(title: "t", content: "c", folderID: folder,
                                     createdAt: Date(timeIntervalSince1970: 1),
                                     updatedAt: Date(timeIntervalSince1970: 2),
                                     deletedAt: Date(timeIntervalSince1970: 3))
        let data = try JSONEncoder().encode(VaultData(documents: [original]))
        let back = try JSONDecoder().decode(VaultData.self, from: data)
        XCTAssertEqual(back.documents, [original])
    }

    func testDocumentWrittenBeforeSoftDeleteStillDecodes() throws {
        // Vaults from before the `deletedAt` field carry no such key.
        let json = """
        {"folders":[],"documents":[{"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8",
        "title":"old","content":"body","createdAt":0,"updatedAt":0}]}
        """
        let back = try JSONDecoder().decode(VaultData.self, from: Data(json.utf8))
        XCTAssertEqual(back.documents.count, 1)
        XCTAssertNil(back.documents.first?.deletedAt)
        XCTAssertNil(back.documents.first?.folderID)
        XCTAssertEqual(back.documents(in: nil).map(\.title), ["old"])
    }
}
