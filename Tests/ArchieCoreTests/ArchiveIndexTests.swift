import ArchieCore
import XCTest

final class ArchiveIndexTests: XCTestCase {
    func testCompleteSidecarIncluded() async throws {
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

        let report = await collectVerify(root)
        XCTAssertEqual(report.complete, ["asset-ok"])
        XCTAssertEqual(report.incomplete, 0)
    }

    func testMissingResourceExcluded() async throws {
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

        let report = await collectVerify(root)
        XCTAssertTrue(report.complete.isEmpty)
        XCTAssertEqual(report.incomplete, 1)
    }

    func testHashMismatchExcluded() async throws {
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

        let report = await collectVerify(root)
        XCTAssertTrue(report.complete.isEmpty)
        XCTAssertEqual(report.incomplete, 1)

        // Presence list skips SHA — size+path match is enough for import resume.
        let present = ArchiveIndex.listPresentAssetIds(archiveRoot: root)
        XCTAssertEqual(present, ["asset-badhash"])
    }

    func testListPresentSkipsMissingResource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-idx-present-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let doc = SidecarDocument(
            assetId: "asset-gone",
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

        XCTAssertTrue(ArchiveIndex.listPresentAssetIds(archiveRoot: root).isEmpty)
    }

    private func collectVerify(_ root: URL) async -> (complete: [String], incomplete: Int) {
        var complete: [String] = []
        var incomplete = 0
        for await progress in ArchiveIndex.verifyStream(archiveRoot: root, progressEvery: 1) {
            complete.append(contentsOf: progress.completeAssetIds)
            incomplete = progress.incompleteCount
        }
        return (complete, incomplete)
    }

    private func hash(_ data: Data) throws -> String {
        let h = Sha256Hasher()
        h.update(data)
        return h.finalize()
    }
}
