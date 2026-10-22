import ArchieCore
import XCTest

final class FavouritesSeenLogTests: XCTestCase {
    func testRecordAndLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-fav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FavouritesSeenLog.record(assetId: "a1", archiveRoot: root)
        try FavouritesSeenLog.record(assetId: "a1", archiveRoot: root)
        try FavouritesSeenLog.record(assetId: "a2", archiveRoot: root)

        let ids = FavouritesSeenLog.load(archiveRoot: root)
        XCTAssertEqual(ids, Set(["a1", "a2"]))
    }

    func testMergeFromFavouriteSidecar() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-fav-merge-\(UUID().uuidString)", isDirectory: true)
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

        let ids = try FavouritesSeenLog.loadMergingSidecars(archiveRoot: root)
        XCTAssertTrue(ids.contains("fav-asset"))
        XCTAssertEqual(FavouritesSeenLog.load(archiveRoot: root), ids)
    }
}
