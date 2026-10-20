import ArchieCore
import Foundation

/// Mac side: receives one resource at a time, writes atomically, replies with receipt/fail.
final class SessionHandler {
    private let io: ConnectionIO
    private let archiveRoot: URL
    private let pin: String
    private let manifest: ManifestStore
    private var writer: AtomicWriter?
    private var currentBegin: AssetBeginPayload?

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
}
