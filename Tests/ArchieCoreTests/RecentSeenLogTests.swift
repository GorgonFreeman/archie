import ArchieCore
import XCTest

final class RecentSeenLogTests: XCTestCase {
    func testRecordLoadAndRemove() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try RecentSeenLog.record(assetId: "a1", creationDate: date, archiveRoot: root)
        try RecentSeenLog.record(assetId: "a1", creationDate: date, archiveRoot: root)
        try RecentSeenLog.record(assetId: "a2", creationDate: nil, archiveRoot: root)

        let entries = RecentSeenLog.load(archiveRoot: root)
        XCTAssertEqual(Set(entries.map(\.assetId)), Set(["a1", "a2"]))
        XCTAssertEqual(entries.first { $0.assetId == "a1" }?.creationDate, date)

        try RecentSeenLog.remove(assetId: "a1", archiveRoot: root)
        XCTAssertEqual(RecentSeenLog.loadIds(archiveRoot: root), Set(["a2"]))
    }

    func testWindowHelpers() {
        let now = Date()
        let young = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let old = Calendar.current.date(byAdding: .day, value: -45, to: now)!
        XCTAssertTrue(RecentSeenLog.isWithinWindow(creationDate: young, now: now))
        XCTAssertFalse(RecentSeenLog.isAgedOut(creationDate: young, now: now))
        XCTAssertFalse(RecentSeenLog.isWithinWindow(creationDate: old, now: now))
        XCTAssertTrue(RecentSeenLog.isAgedOut(creationDate: old, now: now))
        XCTAssertTrue(RecentSeenLog.isAgedOut(creationDate: nil, now: now))
    }
}
