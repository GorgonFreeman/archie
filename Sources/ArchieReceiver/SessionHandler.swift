import ArchieCore
import Foundation

private struct ReceivedResource {
    var relativePath: String
    var sha256: String
    var isSidecar: Bool
}

/// Mac side: receives one resource at a time, writes atomically, replies with receipt/fail.
/// After phone requests settle, renames the asset before acknowledging.
/// Files land in `baseArchiveRoot/<device name>/` after HELLO.
final class SessionHandler {
    private let io: ConnectionIO
    private let baseArchiveRoot: URL
    private let pin: String
    /// Set in `expectHello` to the per-device folder.
    private var archiveRoot: URL
    private var manifest: ManifestStore?
    private var writer: AtomicWriter?
    private var currentBegin: AssetBeginPayload?

    private var assetResources: [String: [ReceivedResource]] = [:]
    private var assetCreationDates: [String: Date] = [:]

    init(io: ConnectionIO, archiveRoot: URL, pin: String) {
        self.io = io
        self.baseArchiveRoot = archiveRoot
        self.archiveRoot = archiveRoot
        self.pin = pin
    }

    func run() async {
        do {
            try await expectHello()
            while true {
                let (type, payload) = try await io.receive()
                switch type {
                case .assetBegin:
                    try await beginResource(payload)
                case .chunk:
                    try appendChunk(payload)
                case .resourceEnd:
                    try await endResource(payload)
                case .assetSettle:
                    try await settleAsset(payload)
                case .archiveIndex:
                    try await sendArchiveIndex()
                case .protectedSeenFetch:
                    try await sendProtectedSeen()
                case .protectedSeenMark:
                    try await markProtectedSeen(payload)
                case .settledIdsFetch:
                    try await sendSettledIds()
                case .libraryInventoryBegin:
                    try await receiveLibraryInventory(firstPayload: payload)
                case .ping:
                    try await io.send(type: .pong)
                case .sessionEnd:
                    fputs("session end\n", stderr)
                    return
                default:
                    throw ReceiverError.protocolError("unexpected frame \(type.rawValue)")
                }
            }
        } catch {
            writer?.abort()
            writer = nil
            fputs("session error: \(error.localizedDescription)\n", stderr)
        }
    }

    private func expectHello() async throws {
        let (type, payload) = try await io.receive()
        guard type == .hello else { throw ReceiverError.protocolError("expected HELLO") }
        let hello = try MessageCodec.decode(HelloPayload.self, from: payload)
        guard hello.pin == pin else {
            try await io.sendJSON(type: .fail, value: FailPayload(reason: "bad pin"))
            throw ReceiverError.badPin
        }

        let deviceRoot = DeviceArchive.root(
            baseArchiveRoot: baseArchiveRoot,
            deviceName: hello.deviceName
        )
        try FileManager.default.createDirectory(at: deviceRoot, withIntermediateDirectories: true)
        archiveRoot = deviceRoot
        manifest = try ManifestStore(archiveRoot: deviceRoot)

        try await io.sendJSON(
            type: .hello,
            value: HelloPayload(role: "mac", deviceName: Host.current().localizedName)
        )
        fputs(
            "paired with \(hello.deviceName ?? "iphone") → \(deviceRoot.path)\n",
            stderr
        )
    }

    private func requireManifest() throws -> ManifestStore {
        guard let manifest else {
            throw ReceiverError.protocolError("session not ready (no HELLO)")
        }
        return manifest
    }

    private func beginResource(_ payload: Data) async throws {
        writer?.abort()
        let begin = try MessageCodec.decode(AssetBeginPayload.self, from: payload)
        currentBegin = begin
        if let date = begin.creationDate {
            assetCreationDates[begin.assetId] = date
        }
        writer = try AtomicWriter(
            archiveRoot: archiveRoot,
            originalFilename: begin.originalFilename,
            creationDate: begin.creationDate,
            expectedSize: begin.size,
            declaredSha256: begin.declaredSha256
        )
    }

    private func appendChunk(_ data: Data) throws {
        guard let writer else { throw ReceiverError.protocolError("chunk without begin") }
        try writer.append(data)
    }

    private func endResource(_ payload: Data) async throws {
        let manifest = try requireManifest()
        guard let writer, let begin = currentBegin else {
            throw ReceiverError.protocolError("end without begin")
        }
        let end = try MessageCodec.decode(ResourceEndPayload.self, from: payload)
        guard end.sha256.lowercased() == begin.declaredSha256.lowercased(),
              end.size == begin.size else {
            writer.abort()
            self.writer = nil
            currentBegin = nil
            try await io.sendJSON(type: .fail, value: FailPayload(reason: "end metadata mismatch"))
            return
        }
        do {
            let result = try writer.finish()
            try manifest.append(ManifestRecord(
                assetId: begin.assetId,
                resourceType: begin.resourceType,
                relativePath: result.relativePath,
                size: result.size,
                sha256: result.sha256
            ))
            var list = assetResources[begin.assetId] ?? []
            list.append(ReceivedResource(
                relativePath: result.relativePath,
                sha256: result.sha256,
                isSidecar: begin.isSidecar || begin.resourceType == "sidecar"
            ))
            assetResources[begin.assetId] = list

            try await io.sendJSON(
                type: .receipt,
                value: ReceiptPayload(
                    sha256: result.sha256,
                    size: result.size,
                    relativePath: result.relativePath
                )
            )
            fputs("ok \(result.relativePath)\n", stderr)
        } catch {
            writer.abort()
            try await io.sendJSON(type: .fail, value: FailPayload(reason: error.localizedDescription))
            fputs("fail \(error.localizedDescription)\n", stderr)
        }
        self.writer = nil
        currentBegin = nil
    }

    private func sendProtectedSeen() async throws {
        do {
            var ids = ProtectedSeenLog.load(archiveRoot: archiveRoot)
            // Legacy flat archive at the base root (pre device-folder layout).
            if archiveRoot.standardizedFileURL != baseArchiveRoot.standardizedFileURL {
                ids.formUnion(ProtectedSeenLog.load(archiveRoot: baseArchiveRoot))
            }
            try await io.sendJSON(
                type: .protectedSeenResult,
                value: ProtectedSeenPayload(assetIds: Array(ids).sorted())
            )
            fputs("protected seen: \(ids.count)\n", stderr)
        } catch {
            try await io.sendJSON(
                type: .fail,
                value: FailPayload(reason: "protected log: \(error.localizedDescription)")
            )
        }
    }

    private func markProtectedSeen(_ payload: Data) async throws {
        let request = try MessageCodec.decode(ProtectedSeenMarkPayload.self, from: payload)
        do {
            try ProtectedSeenLog.record(assetId: request.assetId, archiveRoot: archiveRoot)
            try await io.sendJSON(
                type: .protectedSeenResult,
                value: ProtectedSeenPayload(assetIds: [request.assetId])
            )
        } catch {
            try await io.sendJSON(
                type: .fail,
                value: FailPayload(reason: "protected mark: \(error.localizedDescription)")
            )
        }
    }

    private func sendSettledIds() async throws {
        do {
            var ids = ArchiveIndex.listPresentAssetIds(archiveRoot: archiveRoot)
            if archiveRoot.standardizedFileURL != baseArchiveRoot.standardizedFileURL {
                ids.formUnion(ArchiveIndex.listPresentAssetIds(archiveRoot: baseArchiveRoot))
            }
            try await io.sendJSON(
                type: .settledIdsResult,
                value: SettledIdsPayload(assetIds: Array(ids).sorted())
            )
            fputs("settled ids: \(ids.count)\n", stderr)
        } catch {
            try await io.sendJSON(
                type: .fail,
                value: FailPayload(reason: "settled ids: \(error.localizedDescription)")
            )
        }
    }

    private func receiveLibraryInventory(firstPayload: Data) async throws {
        let begin = try MessageCodec.decode(LibraryInventoryBeginPayload.self, from: firstPayload)
        var ids: [String] = []
        ids.reserveCapacity(max(0, begin.total))
        while true {
            let (type, payload) = try await io.receive()
            switch type {
            case .libraryInventoryChunk:
                let chunk = try MessageCodec.decode(SettledIdsPayload.self, from: payload)
                ids.append(contentsOf: chunk.assetIds)
            case .libraryInventoryEnd:
                let checkpoint = LibraryCheckpoint(
                    label: begin.label.isEmpty ? "manual" : begin.label,
                    deviceName: begin.deviceName,
                    assetIds: ids
                )
                do {
                    let url = try LibraryCheckpointStore.save(checkpoint)
                    try await io.sendJSON(
                        type: .libraryInventoryAck,
                        value: LibraryInventoryAckPayload(
                            assetCount: checkpoint.assetCount,
                            path: url.path
                        )
                    )
                    fputs(
                        "checkpoint \(checkpoint.label): \(checkpoint.assetCount) assets → \(url.path)\n",
                        stderr
                    )
                } catch {
                    try await io.sendJSON(
                        type: .fail,
                        value: FailPayload(reason: "checkpoint: \(error.localizedDescription)")
                    )
                }
                return
            case .fail:
                return
            default:
                throw ReceiverError.protocolError("unexpected frame during library inventory")
            }
        }
    }

    private func sendArchiveIndex() async throws {
        fputs("archive index: streaming verify (sha256)…\n", stderr)
        var completeTotal = 0
        var lastIncomplete = 0

        func stream(_ root: URL) async throws {
            var incompleteThisRoot = 0
            for await progress in ArchiveIndex.verifyStream(archiveRoot: root, progressEvery: 15) {
                completeTotal += progress.completeAssetIds.count
                incompleteThisRoot = progress.incompleteCount
                try await io.sendJSON(
                    type: .archiveIndexProgress,
                    value: ArchiveIndexProgressPayload(
                        scanned: progress.scanned,
                        total: progress.total,
                        incompleteCount: lastIncomplete + incompleteThisRoot,
                        completeAssetIds: progress.completeAssetIds,
                        finished: false
                    )
                )
            }
            lastIncomplete += incompleteThisRoot
        }

        try await stream(archiveRoot)
        // Legacy flat files directly under the base archive (skips device subfolders).
        if archiveRoot.standardizedFileURL != baseArchiveRoot.standardizedFileURL {
            try await stream(baseArchiveRoot)
        }

        try await io.sendJSON(
            type: .archiveIndexProgress,
            value: ArchiveIndexProgressPayload(
                scanned: completeTotal,
                total: completeTotal,
                incompleteCount: lastIncomplete,
                completeAssetIds: [],
                finished: true
            )
        )
        try await io.sendJSON(
            type: .archiveIndexResult,
            value: ArchiveIndexPayload(assetIds: [], incompleteCount: lastIncomplete)
        )
        fputs(
            "archive index done complete≈\(completeTotal) incomplete=\(lastIncomplete)\n",
            stderr
        )
    }

    private func settleAsset(_ payload: Data) async throws {
        let manifest = try requireManifest()
        let request = try MessageCodec.decode(AssetSettlePayload.self, from: payload)
        guard let resources = assetResources[request.assetId], !resources.isEmpty else {
            try await io.sendJSON(
                type: .fail,
                value: FailPayload(reason: "unknown asset for settle")
            )
            return
        }

        let settled = resources.map {
            SettledResource(
                relativePath: $0.relativePath,
                sha256: $0.sha256,
                isSidecar: $0.isSidecar
            )
        }

        do {
            let pathMap = try AssetRenamer.settle(
                archiveRoot: archiveRoot,
                assetId: request.assetId,
                creationDate: assetCreationDates[request.assetId],
                resources: settled,
                manifest: manifest
            )
            assetResources[request.assetId] = settled.map { r in
                ReceivedResource(
                    relativePath: pathMap[r.relativePath] ?? r.relativePath,
                    sha256: r.sha256,
                    isSidecar: r.isSidecar
                )
            }
            if var list = assetResources[request.assetId] {
                for i in list.indices where list[i].isSidecar {
                    let url = archiveRoot.appendingPathComponent(list[i].relativePath)
                    if let dig = try? Sha256Hasher.hash(fileAt: url) {
                        list[i].sha256 = dig
                    }
                }
                assetResources[request.assetId] = list
            }

            let mappings = pathMap.map { PathMapping(from: $0.key, to: $0.value) }
                .sorted { $0.from < $1.from }
            try await io.sendJSON(
                type: .assetSettled,
                value: AssetSettledPayload(assetId: request.assetId, paths: mappings)
            )
            fputs("settled \(request.assetId) (\(mappings.count) renames)\n", stderr)
        } catch {
            try await io.sendJSON(
                type: .fail,
                value: FailPayload(reason: "settle failed: \(error.localizedDescription)")
            )
            fputs("settle fail \(error.localizedDescription)\n", stderr)
        }
    }
}
