import ArchieCore
import XCTest

final class AssetRenamerTests: XCTestCase {
    private var root: URL!
    private var manifest: ManifestStore!
    private var creationDate: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manifest = try ManifestStore(archiveRoot: root)

        var comps = DateComponents()
        comps.year = 2020
        comps.month = 1
        comps.day = 15
        comps.hour = 14
        comps.minute = 30
        comps.second = 45
        creationDate = Calendar.current.date(from: comps)!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMultiResourceRenameUpdatesSidecarAndManifest() throws {
        let heic = try writeMedia(name: "IMG_1001.HEIC", bytes: Data([0x01, 0x02, 0x03]))
        let mov = try writeMedia(name: "IMG_1001.MOV", bytes: Data([0x0A, 0x0B, 0x0C, 0x0D]))
        let assetId = "asset-live"
        let side = try writeSidecar(
            assetId: assetId,
            media: [
                (type: "photo", path: heic.name, sha: heic.sha, size: heic.size),
                (type: "pairedVideo", path: mov.name, sha: mov.sha, size: mov.size),
            ]
        )
        try manifest.append(ManifestRecord(
            assetId: assetId,
            resourceType: "photo",
            relativePath: heic.name,
            size: heic.size,
            sha256: heic.sha
        ))
        try manifest.append(ManifestRecord(
            assetId: assetId,
            resourceType: "pairedVideo",
            relativePath: mov.name,
            size: mov.size,
            sha256: mov.sha
        ))
        try manifest.append(ManifestRecord(
            assetId: assetId,
            resourceType: "sidecar",
            relativePath: side.name,
            size: side.size,
            sha256: side.sha
        ))

        let pathMap = try AssetRenamer.settle(
            archiveRoot: root,
            assetId: assetId,
            creationDate: creationDate,
            resources: [
                SettledResource(relativePath: heic.name, sha256: heic.sha, isSidecar: false),
                SettledResource(relativePath: mov.name, sha256: mov.sha, isSidecar: false),
                SettledResource(relativePath: side.name, sha256: side.sha, isSidecar: true),
            ],
            manifest: manifest
        )

        let expectedHeic = "2020-01-15_14h30m45s.HEIC"
        let expectedMov = "2020-01-15_14h30m45s.MOV"
        let expectedSide = expectedHeic + ArchieConstants.sidecarSuffix

        XCTAssertEqual(pathMap[heic.name], expectedHeic)
        XCTAssertEqual(pathMap[mov.name], expectedMov)
        XCTAssertEqual(pathMap[side.name], expectedSide)

        XCTAssertTrue(exists(expectedHeic))
        XCTAssertTrue(exists(expectedMov))
        XCTAssertTrue(exists(expectedSide))
        XCTAssertFalse(exists(heic.name))
        XCTAssertFalse(exists(mov.name))
        XCTAssertFalse(exists(side.name))

        // Content hashes unchanged for media.
        XCTAssertEqual(try Sha256Hasher.hash(fileAt: root.appendingPathComponent(expectedHeic)), heic.sha)
        XCTAssertEqual(try Sha256Hasher.hash(fileAt: root.appendingPathComponent(expectedMov)), mov.sha)

        let doc = try MessageCodec.decode(
            SidecarDocument.self,
            from: Data(contentsOf: root.appendingPathComponent(expectedSide))
        )
        XCTAssertEqual(Set(doc.resources.map(\.relativePath)), Set([expectedHeic, expectedMov]))

        let rows = try readManifest()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map(\.relativePath)), Set([expectedHeic, expectedMov, expectedSide]))
        let sideRow = try XCTUnwrap(rows.first { $0.resourceType == "sidecar" })
        XCTAssertEqual(sideRow.sha256, try Sha256Hasher.hash(fileAt: root.appendingPathComponent(expectedSide)))
    }

    func testCollisionUsesNumericSuffix() throws {
        let blocker = "2020-01-15_14h30m45s.HEIC"
        try Data([0xFF]).write(to: root.appendingPathComponent(blocker))

        let heic = try writeMedia(name: "IMG_2002.HEIC", bytes: Data([0x11, 0x22]))
        let assetId = "asset-collide"
        let side = try writeSidecar(
            assetId: assetId,
            media: [(type: "photo", path: heic.name, sha: heic.sha, size: heic.size)]
        )
        try appendBasicManifest(assetId: assetId, heic: heic, side: side)

        let pathMap = try AssetRenamer.settle(
            archiveRoot: root,
            assetId: assetId,
            creationDate: creationDate,
            resources: [
                SettledResource(relativePath: heic.name, sha256: heic.sha, isSidecar: false),
                SettledResource(relativePath: side.name, sha256: side.sha, isSidecar: true),
            ],
            manifest: manifest
        )

        XCTAssertEqual(pathMap[heic.name], "2020-01-15_14h30m45s_1.HEIC")
        XCTAssertTrue(exists("2020-01-15_14h30m45s_1.HEIC"))
        XCTAssertTrue(exists(blocker))
        XCTAssertEqual(try Sha256Hasher.hash(fileAt: root.appendingPathComponent(blocker)), try hash(Data([0xFF])))
    }

    func testIdempotentWhenAlreadySettled() throws {
        let heic = try writeMedia(name: "IMG_3003.HEIC", bytes: Data([0x33]))
        let assetId = "asset-idem"
        let side = try writeSidecar(
            assetId: assetId,
            media: [(type: "photo", path: heic.name, sha: heic.sha, size: heic.size)]
        )
        try appendBasicManifest(assetId: assetId, heic: heic, side: side)

        let first = try AssetRenamer.settle(
            archiveRoot: root,
            assetId: assetId,
            creationDate: creationDate,
            resources: [
                SettledResource(relativePath: heic.name, sha256: heic.sha, isSidecar: false),
                SettledResource(relativePath: side.name, sha256: side.sha, isSidecar: true),
            ],
            manifest: manifest
        )
        XCTAssertFalse(first.isEmpty)

        let newHeic = first[heic.name]!
        let newSide = first[side.name]!
        let newHeicSha = try Sha256Hasher.hash(fileAt: root.appendingPathComponent(newHeic))
        let newSideSha = try Sha256Hasher.hash(fileAt: root.appendingPathComponent(newSide))

        let second = try AssetRenamer.settle(
            archiveRoot: root,
            assetId: assetId,
            creationDate: creationDate,
            resources: [
                SettledResource(relativePath: newHeic, sha256: newHeicSha, isSidecar: false),
                SettledResource(relativePath: newSide, sha256: newSideSha, isSidecar: true),
            ],
            manifest: manifest
        )
        XCTAssertTrue(second.isEmpty)
        XCTAssertTrue(exists(newHeic))
        XCTAssertTrue(exists(newSide))
    }

    func testHashMismatchLeavesFilesUntouched() throws {
        let heic = try writeMedia(name: "IMG_4004.HEIC", bytes: Data([0x44]))
        let assetId = "asset-hash"
        let side = try writeSidecar(
            assetId: assetId,
            media: [(type: "photo", path: heic.name, sha: heic.sha, size: heic.size)]
        )
        try appendBasicManifest(assetId: assetId, heic: heic, side: side)

        XCTAssertThrowsError(
            try AssetRenamer.settle(
                archiveRoot: root,
                assetId: assetId,
                creationDate: creationDate,
                resources: [
                    SettledResource(relativePath: heic.name, sha256: "deadbeef", isSidecar: false),
                    SettledResource(relativePath: side.name, sha256: side.sha, isSidecar: true),
                ],
                manifest: manifest
            )
        )

        XCTAssertTrue(exists(heic.name))
        XCTAssertTrue(exists(side.name))
        XCTAssertFalse(exists("2020-01-15_14h30m45s.HEIC"))
    }

    func testSidecarDecodeFailureRollsBackMedia() throws {
        let heic = try writeMedia(name: "IMG_5005.HEIC", bytes: Data([0x55, 0x56]))
        let mov = try writeMedia(name: "IMG_5005.MOV", bytes: Data([0x57]))
        let badSidecarName = "IMG_5005.HEIC.asset.json"
        let badBytes = Data("{not-json".utf8)
        try badBytes.write(to: root.appendingPathComponent(badSidecarName))
        let badSha = try hash(badBytes)

        try manifest.append(ManifestRecord(
            assetId: "asset-bad-side",
            resourceType: "photo",
            relativePath: heic.name,
            size: heic.size,
            sha256: heic.sha
        ))
        try manifest.append(ManifestRecord(
            assetId: "asset-bad-side",
            resourceType: "pairedVideo",
            relativePath: mov.name,
            size: mov.size,
            sha256: mov.sha
        ))
        try manifest.append(ManifestRecord(
            assetId: "asset-bad-side",
            resourceType: "sidecar",
            relativePath: badSidecarName,
            size: Int64(badBytes.count),
            sha256: badSha
        ))

        XCTAssertThrowsError(
            try AssetRenamer.settle(
                archiveRoot: root,
                assetId: "asset-bad-side",
                creationDate: creationDate,
                resources: [
                    SettledResource(relativePath: heic.name, sha256: heic.sha, isSidecar: false),
                    SettledResource(relativePath: mov.name, sha256: mov.sha, isSidecar: false),
                    SettledResource(relativePath: badSidecarName, sha256: badSha, isSidecar: true),
                ],
                manifest: manifest
            )
        )

        XCTAssertTrue(exists(heic.name))
        XCTAssertTrue(exists(mov.name))
        XCTAssertTrue(exists(badSidecarName))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(badSidecarName)), badBytes)
        XCTAssertFalse(exists("2020-01-15_14h30m45s.HEIC"))
        XCTAssertFalse(exists("2020-01-15_14h30m45s.MOV"))
        XCTAssertFalse(exists("2020-01-15_14h30m45s.HEIC.asset.json"))

        let rows = try readManifest()
        XCTAssertEqual(Set(rows.map(\.relativePath)), Set([heic.name, mov.name, badSidecarName]))
    }

    // MARK: - Helpers

    private struct Written {
        var name: String
        var sha: String
        var size: Int64
    }

    private func writeMedia(name: String, bytes: Data) throws -> Written {
        try bytes.write(to: root.appendingPathComponent(name))
        return Written(name: name, sha: try hash(bytes), size: Int64(bytes.count))
    }

    private func writeSidecar(
        assetId: String,
        media: [(type: String, path: String, sha: String, size: Int64)]
    ) throws -> Written {
        let primary = media[0].path
        let name = primary + ArchieConstants.sidecarSuffix
        let doc = SidecarDocument(
            assetId: assetId,
            deviceModel: "TestPhone",
            iosVersion: "18.0",
            creationDate: creationDate,
            modificationDate: creationDate,
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
            resources: media.map {
                SidecarResource(
                    type: $0.type,
                    originalFilename: $0.path,
                    size: $0.size,
                    sha256: $0.sha,
                    relativePath: $0.path
                )
            }
        )
        let data = try MessageCodec.encode(doc)
        try data.write(to: root.appendingPathComponent(name))
        return Written(name: name, sha: try hash(data), size: Int64(data.count))
    }

    private func appendBasicManifest(assetId: String, heic: Written, side: Written) throws {
        try manifest.append(ManifestRecord(
            assetId: assetId,
            resourceType: "photo",
            relativePath: heic.name,
            size: heic.size,
            sha256: heic.sha
        ))
        try manifest.append(ManifestRecord(
            assetId: assetId,
            resourceType: "sidecar",
            relativePath: side.name,
            size: side.size,
            sha256: side.sha
        ))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private func hash(_ data: Data) throws -> String {
        let h = Sha256Hasher()
        h.update(data)
        return h.finalize()
    }

    private func readManifest() throws -> [ManifestRecord] {
        let url = root.appendingPathComponent(ArchieConstants.manifestName)
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try MessageCodec.decode(ManifestRecord.self, from: Data($0.utf8)) }
    }
}
