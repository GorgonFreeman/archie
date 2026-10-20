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
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(with: opts)
        total = fetch.count
        progress = 0

        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }

        for asset in assets {
            progress += 1
            status = "Asset \(progress)/\(total)"
            let outcome = await transferVerifyDelete(asset, client: client)
            summary.outcomes.append(outcome)
            summary.imported += 1
            if outcome.verified {
                summary.verified += 1
                summary.bytesVerified += outcome.bytes
            } else {
                summary.failed += 1
            }
            if outcome.deleted {
                summary.deleted += 1
            } else {
                summary.retained += 1
            }
        }

        try? await client.endSession()
        status = "Finished — deleted \(summary.deleted), retained \(summary.retained)"
    }

    /// Transfer → require matching receipts for every resource + sidecar → then maybe delete.
    private func transferVerifyDelete(
        _ asset: PHAsset,
        client: TransferClient
    ) async -> AssetOutcome {
        switch await transferVerified(asset, client: client) {
        case .failure(let reason, let bytes):
            return AssetOutcome(
                id: asset.localIdentifier,
                bytes: bytes,
                verified: false,
                deleted: false,
                retainReason: reason
            )
        case .success(let copy):
            // Delete only via VerifiedCopy — never a bare asset id / bool.
            switch await DeletionService.deleteVerified(copy, settings: settings) {
            case .deleted:
                return AssetOutcome(
                    id: copy.assetId,
                    bytes: copy.bytes,
                    verified: true,
                    deleted: true,
                    retainReason: nil
                )
            case .retained(let reason):
                return AssetOutcome(
                    id: copy.assetId,
                    bytes: copy.bytes,
                    verified: true,
                    deleted: false,
                    retainReason: reason
                )
            }
        }
    }

    private enum TransferResult {
        case success(VerifiedCopy)
        case failure(RetainReason, bytes: Int64)
    }

    /// Returns `VerifiedCopy` only when every media resource and the sidecar have matching RECEIPTs.
    private func transferVerified(
        _ asset: PHAsset,
        client: TransferClient
    ) async -> TransferResult {
        let exported: [ExportedResource]
        do {
            exported = try await ResourceExporter.exportAll(for: asset)
        } catch {
            return .failure(.unreadable, bytes: 0)
        }
        guard !exported.isEmpty else {
            return .failure(.unreadable, bytes: 0)
        }

        var matched: [MatchedReceipt] = []
        var bytes: Int64 = 0
        var sidecarResources: [SidecarResource] = []

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
                matched.append(MatchedReceipt(
                    type: resource.typeName,
                    originalFilename: resource.originalFilename,
                    size: receipt.size,
                    sha256: receipt.sha256,
                    relativePath: receipt.relativePath
                ))
                sidecarResources.append(SidecarResource(
                    type: resource.typeName,
                    originalFilename: resource.originalFilename,
                    size: receipt.size,
                    sha256: receipt.sha256,
                    relativePath: receipt.relativePath
                ))
                bytes += receipt.size
            } catch {
                return .failure(.failed, bytes: bytes)
            }
        }

        // Sidecar is mandatory — no VerifiedCopy without its receipt.
        let doc = SidecarBuilder.build(asset: asset, resources: sidecarResources)
        let primaryName = exported.first?.originalFilename ?? "asset"
        let sidecarName = "\(primaryName).asset.json"
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-sidecar-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: sidecarURL) }

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
            let receipt = try await sendWithRetry(client: client, begin: begin, file: sidecarURL)
            matched.append(MatchedReceipt(
                type: "sidecar",
                originalFilename: sidecarName,
                size: receipt.size,
                sha256: receipt.sha256,
                relativePath: receipt.relativePath
            ))
        } catch {
            return .failure(.sidecarFailed, bytes: bytes)
        }

        guard let copy = VerifiedCopy.make(
            assetId: asset.localIdentifier,
            expectedMediaCount: exported.count,
            receipts: matched
        ) else {
            return .failure(.failed, bytes: bytes)
        }
        return .success(copy)
    }

    private func sendWithRetry(
        client: TransferClient,
        begin: AssetBeginPayload,
        file: URL
    ) async throws -> ReceiptPayload {
        var last: Error = TransferError.protocolError("no attempt")
        for _ in 0..<ArchieConstants.maxAttempts {
            do {
                return try await client.sendResource(begin: begin, bytes: fileChunkStream(file))
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
