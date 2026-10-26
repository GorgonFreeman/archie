import ArchieCore
import XCTest

final class LibraryCheckpointTests: XCTestCase {
    func testCompareRemovedAndAdded() throws {
        let before = LibraryCheckpoint(
            label: "baseline",
            deviceName: "TestPhone",
            assetIds: ["a", "b", "c"]
        )
        let after = LibraryCheckpoint(
            label: "post-import",
            deviceName: "TestPhone",
            assetIds: ["b", "c", "d"]
        )
        let diff = LibraryCheckpointStore.compare(before: before, after: after)
        XCTAssertEqual(diff.beforeCount, 3)
        XCTAssertEqual(diff.afterCount, 3)
        XCTAssertEqual(diff.removedCount, 1)
        XCTAssertEqual(diff.addedCount, 1)
        XCTAssertEqual(diff.removedIds, ["a"])
        XCTAssertEqual(diff.addedIds, ["d"])
        XCTAssertEqual(diff.netChange, 0)
    }

    func testSaveRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-ckpt-\(UUID().uuidString)", isDirectory: true)
        // Exercise encode/decode via MessageCodec (store uses Application Support — unit test local).
        let ckpt = LibraryCheckpoint(
            label: "baseline",
            deviceName: "Phone",
            assetIds: ["id-1", "id-2"]
        )
        let data = try MessageCodec.encode(ckpt)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.json")
        try data.write(to: url)
        let loaded = try LibraryCheckpointStore.load(from: url)
        XCTAssertEqual(loaded.assetCount, 2)
        XCTAssertEqual(loaded.assetIds, ["id-1", "id-2"])
        XCTAssertEqual(loaded.label, "baseline")
    }
}
