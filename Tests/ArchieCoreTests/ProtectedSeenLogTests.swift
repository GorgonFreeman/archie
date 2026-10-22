import ArchieCore
import XCTest

final class ProtectedSeenLogTests: XCTestCase {
    func testRecordAndLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-prot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try ProtectedSeenLog.record(assetId: "a1", archiveRoot: root)
        try ProtectedSeenLog.record(assetId: "a1", archiveRoot: root)
        try ProtectedSeenLog.record(assetId: "a2", archiveRoot: root)

        let ids = ProtectedSeenLog.load(archiveRoot: root)
        XCTAssertEqual(ids, Set(["a1", "a2"]))
    }

    func testMigratesLegacyFavouritesLog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-prot-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent(ArchieConstants.legacyFavouritesSeenLogName)
        try "legacy-id\n".write(to: legacy, atomically: true, encoding: .utf8)

        let ids = ProtectedSeenLog.load(archiveRoot: root)
        XCTAssertEqual(ids, Set(["legacy-id"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProtectedSeenLog.url(in: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testMergeFromFavouriteSidecar() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-prot-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let name = "2020-01-15_14h30m45s.heic"
        let doc = SidecarDocument(
            assetId: "fav-asset",
            deviceModel: "Test",
            iosVersion: "18",
            creationDate: Date(),
            modificationDate: nil,
            location: nil,
            isFavorite: true,
            isHidden: false,
            albums: [],
            mediaType: "image",
            subtypes: [],
            burstIdentifier: nil,
            pixelWidth: 1,
            pixelHeight: 1,
            duration: 0,
            resources: []
        )
        try MessageCodec.encode(doc).write(
            to: root.appendingPathComponent(name + ArchieConstants.sidecarSuffix)
        )

        let ids = try ProtectedSeenLog.loadMergingSidecars(archiveRoot: root)
        XCTAssertTrue(ids.contains("fav-asset"))
        XCTAssertEqual(ProtectedSeenLog.load(archiveRoot: root), ids)
    }
}
