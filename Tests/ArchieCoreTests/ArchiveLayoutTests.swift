import ArchieCore
import XCTest

final class ArchiveLayoutTests: XCTestCase {
    func testUniqueURLIsFlat() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = ArchiveLayout.uniqueURL(
            archiveRoot: root,
            originalFilename: "IMG.HEIC",
            creationDate: Date()
        )
        XCTAssertEqual(first.relativePath, "IMG.HEIC")
        try Data([1]).write(to: first.url)

        let second = ArchiveLayout.uniqueURL(
            archiveRoot: root,
            originalFilename: "IMG.HEIC",
            creationDate: Date()
        )
        XCTAssertEqual(second.relativePath, "IMG-1.HEIC")
    }

    func testAtomicWriterRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-aw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let hasher = Sha256Hasher()
        hasher.update(bytes)
        let digest = hasher.finalize()

        let writer = try AtomicWriter(
            archiveRoot: root,
            originalFilename: "x.bin",
            creationDate: Date(),
            expectedSize: Int64(bytes.count),
            declaredSha256: digest
        )
        try writer.append(bytes)
        let result = try writer.finish()
        XCTAssertEqual(result.sha256, digest)
        XCTAssertEqual(result.size, Int64(bytes.count))
        let onDisk = try Sha256Hasher.hash(fileAt: root.appendingPathComponent(result.relativePath))
        XCTAssertEqual(onDisk, digest)
    }
}
