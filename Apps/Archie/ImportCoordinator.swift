import Foundation
import Photos
import UIKit

@MainActor
final class ImportCoordinator: ObservableObject {
    @Published var status = "Idle"
    @Published var progress = 0
    @Published var total = 0
    @Published var summary = ImportSummary()
    @Published var isRunning = false

    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func run(pin: String) async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        UIApplication.shared.isIdleTimerDisabled = true
        summary = ImportSummary()

        _ = await PhotoAccess.request()
        guard PhotoAccess.canImport else {
            status = "Photos access required"
            return
        }

        status = "Connecting…"
        let client = TransferClient(pin: pin, deviceName: UIDevice.current.name)
        do {
            try await client.connect()
        } catch {
            status = "Connect failed: \(error.localizedDescription)"
            return
        }

        let opts = PHFetchOptions()
        opts.includeHiddenAssets = true
        opts.includeAllBurstAssets = true
        let fetch = PHAsset.fetchAssets(with: opts)
        total = fetch.count
        progress = 0

        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }

        for asset in assets {
            progress += 1
            status = "Asset \(progress)/\(total)"
            let outcome = await transferAsset(asset, client: client)
            summary.outcomes.append(outcome)
            summary.imported += 1
            if outcome.verified {
                summary.verified += 1
                summary.bytesVerified += outcome.bytes
            } else {
                summary.failed += 1
                summary.retained += 1
            }
        }

        try? await client.endSession()
        status = "Import finished"
    }

    private func transferAsset(
        _ asset: PHAsset,
        client: TransferClient
    ) async -> AssetOutcome {
        let exported: [ExportedResource]
        do {
            exported = try await ResourceExporter.exportAll(for: asset)
        } catch {
            return AssetOutcome(
                id: asset.localIdentifier,
                bytes: 0,
                verified: false,
                retainReason: .unreadable
            )
        }

        guard !exported.isEmpty else {
            return AssetOutcome(
                id: asset.localIdentifier,
                bytes: 0,
                verified: false,
                retainReason: .unreadable
            )
        }

        var sidecarResources: [SidecarResource] = []
        var bytes: Int64 = 0
        var allOk = true

        for resource in exported {
            defer { try? FileManager.default.removeItem(at: resource.fileURL) }
            let begin = AssetBeginPayload(
                assetId: asset.localIdentifier,
                resourceType: resource.typeName,
                originalFilename: resource.originalFilename,
                creationDate: asset.creationDate,
                size: resource.size,
                declaredSha256: resource.sha256
            )
            do {
                let receipt = try await sendWithRetry(client: client, begin: begin, file: resource.fileURL)
                sidecarResources.append(SidecarResource(
                    type: resource.typeName,
                    originalFilename: resource.originalFilename,
                    size: resource.size,
                    sha256: resource.sha256,
                    relativePath: receipt.relativePath
                ))
                bytes += resource.size
            } catch {
                allOk = false
                break
            }
        }

        guard allOk else {
            return AssetOutcome(
                id: asset.localIdentifier,
                bytes: bytes,
                verified: false,
                retainReason: .failed
            )
        }

        let doc = SidecarBuilder.build(asset: asset, resources: sidecarResources)
        let primaryName = exported.first?.originalFilename ?? "asset"
        let sidecarName = "\(primaryName).asset.json"
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-sidecar-\(UUID().uuidString).json")
        do {
            let data = try MessageCodec.encode(doc)
            try data.write(to: sidecarURL)
            let hasher = Sha256Hasher()
            hasher.update(data)
            let digest = hasher.finalize()
            let begin = AssetBeginPayload(
                assetId: asset.localIdentifier,
                resourceType: "sidecar",
                originalFilename: sidecarName,
                creationDate: asset.creationDate,
                size: Int64(data.count),
                declaredSha256: digest,
                isSidecar: true
            )
            _ = try await sendWithRetry(client: client, begin: begin, file: sidecarURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        } catch {
            try? FileManager.default.removeItem(at: sidecarURL)
            return AssetOutcome(
                id: asset.localIdentifier,
                bytes: bytes,
                verified: false,
                retainReason: .sidecarFailed
            )
        }

        // Protection is re-evaluated at delete time (spec).
        return AssetOutcome(
            id: asset.localIdentifier,
            bytes: bytes,
            verified: true,
            retainReason: nil
        )
    }

    private func sendWithRetry(
        client: TransferClient,
        begin: AssetBeginPayload,
        file: URL
    ) async throws -> ReceiptPayload {
        var last: Error = TransferError.protocolError("no attempt")
        for _ in 0..<ArchieConstants.maxAttempts {
            do {
                let stream = fileChunkStream(file)
                return try await client.sendResource(begin: begin, bytes: stream)
            } catch {
                last = error
            }
        }
        throw last
    }

    private func fileChunkStream(_ url: URL) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while true {
                    let chunk = handle.readData(ofLength: ArchieConstants.chunkSize)
                    if chunk.isEmpty { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
