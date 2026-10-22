import ArchieCore
import XCTest

final class ArchiveIndexTests: XCTestCase {
    func testCompleteSidecarIncluded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-idx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data([0x01, 0x02, 0x03])
        let name = "2020-01-15_14h30m45s.heic"
        try bytes.write(to: root.appendingPathComponent(name))
        let sha = try hash(bytes)
        let doc = SidecarDocument(
            assetId: "asset-ok",
            deviceModel: "Test",
            iosVersion: "18",
            creationDate: Date(),
            modificationDate: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            albums: [],
            mediaType: "image",
            subtypes: [],
            burstIdentifier: nil,
            pixelWidth: 1,
            pixelHeight: 1,
            duration: 0,
            resources: [
                SidecarResource(
                    type: "photo",
                    originalFilename: name,
                    size: Int64(bytes.count),
                    sha256: sha,
                    relativePath: name
                ),
            ]
        )
        try MessageCodec.encode(doc).write(
            to: root.appendingPathComponent(name + ArchieConstants.sidecarSuffix)
        )

        let report = ArchiveIndex.verifiedAssetIds(in: root)
        XCTAssertEqual(report.completeAssetIds, ["asset-ok"])
        XCTAssertEqual(report.incompleteCount, 0)
    }

    func testMissingResourceExcluded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-idx-miss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let doc = SidecarDocument(
            assetId: "asset-miss",
            deviceModel: "Test",
            iosVersion: "18",
            creationDate: Date(),
            modificationDate: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            albums: [],
            mediaType: "image",
            subtypes: [],
            burstIdentifier: nil,
            pixelWidth: 1,
            pixelHeight: 1,
            duration: 0,
            resources: [
                SidecarResource(
                    type: "photo",
                    originalFilename: "gone.heic",
                    size: 3,
                    sha256: String(repeating: "a", count: 64),
                    relativePath: "gone.heic"
                ),
            ]
        )
        try MessageCodec.encode(doc).write(
            to: root.appendingPathComponent("gone.heic" + ArchieConstants.sidecarSuffix)
        )

        let report = ArchiveIndex.verifiedAssetIds(in: root)
        XCTAssertTrue(report.completeAssetIds.isEmpty)
        XCTAssertEqual(report.incompleteCount, 1)
    }

    func testHashMismatchExcluded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-idx-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let name = "2020-01-15_14h30m45s.jpg"
        try Data([0xAA]).write(to: root.appendingPathComponent(name))
        let doc = SidecarDocument(
            assetId: "asset-badhash",
            deviceModel: "Test",
            iosVersion: "18",
            creationDate: Date(),
            modificationDate: nil,
            location: nil,
            isFavorite: false,
            isHidden: false,
            albums: [],
            mediaType: "image",
            subtypes: [],
            burstIdentifier: nil,
            pixelWidth: 1,
            pixelHeight: 1,
            duration: 0,
            resources: [
                SidecarResource(
                    type: "photo",
                    originalFilename: name,
                    size: 1,
                    sha256: String(repeating: "b", count: 64),
                    relativePath: name
                ),
            ]
        )
        try MessageCodec.encode(doc).write(
            to: root.appendingPathComponent(name + ArchieConstants.sidecarSuffix)
        )

        let report = ArchiveIndex.verifiedAssetIds(in: root)
        XCTAssertTrue(report.completeAssetIds.isEmpty)
        XCTAssertEqual(report.incompleteCount, 1)
    }

    private func hash(_ data: Data) throws -> String {
        let h = Sha256Hasher()
        h.update(data)
        return h.finalize()
    }
}
