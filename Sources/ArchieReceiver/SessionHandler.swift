import ArchieCore
import Foundation

private struct ReceivedResource {
    var relativePath: String
    var sha256: String
    var isSidecar: Bool
}

/// Mac side: receives one resource at a time, writes atomically, replies with receipt/fail.
/// After phone requests settle, renames the asset before acknowledging.
final class SessionHandler {
    private let io: ConnectionIO
    private let archiveRoot: URL
    private let pin: String
    private let manifest: ManifestStore
    private var writer: AtomicWriter?
    private var currentBegin: AssetBeginPayload?

    private var assetResources: [String: [ReceivedResource]] = [:]
    private var assetCreationDates: [String: Date] = [:]

    init(io: ConnectionIO, archiveRoot: URL, pin: String, manifest: ManifestStore) {
        self.io = io
        self.archiveRoot = archiveRoot
        self.pin = pin
        self.manifest = manifest
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
        try await io.sendJSON(
            type: .hello,
            value: HelloPayload(role: "mac", deviceName: Host.current().localizedName)
        )
        fputs("paired with \(hello.deviceName ?? "iphone")\n", stderr)
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

    private func sendArchiveIndex() async throws {
        fputs("archive index: streaming verify (sha256)…\n", stderr)
        var completeTotal = 0
        var lastIncomplete = 0
        for await progress in ArchiveIndex.verifyStream(archiveRoot: archiveRoot, progressEvery: 15) {
            completeTotal += progress.completeAssetIds.count
            lastIncomplete = progress.incompleteCount
            try await io.sendJSON(
                type: .archiveIndexProgress,
                value: ArchiveIndexProgressPayload(
                    scanned: progress.scanned,
                    total: progress.total,
                    incompleteCount: progress.incompleteCount,
                    completeAssetIds: progress.completeAssetIds,
                    finished: progress.finished
                )
            )
        }
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
            // Update session paths so a retry sees new names.
            assetResources[request.assetId] = settled.map { r in
                ReceivedResource(
                    relativePath: pathMap[r.relativePath] ?? r.relativePath,
                    sha256: r.sha256,
                    isSidecar: r.isSidecar
                )
            }
            // Sidecar content hash changed — refresh from disk if present.
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
