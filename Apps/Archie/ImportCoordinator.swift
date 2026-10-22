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
    @Published var isPaused = false
    /// Verified+settled assets waiting for a Photos delete confirmation.
    @Published private(set) var pendingDeleteCount = 0
    /// Archive leftovers still on the phone — UI presents an alert.
    @Published var leftoverOffer: LeftoverDeleteOffer?

    private let settings: SettingsStore
    private var pendingDeletes: [VerifiedCopy] = []
    private var flushTask: Task<Void, Never>?
    private var leftoverDecision: CheckedContinuation<Bool, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    struct LeftoverDeleteOffer: Identifiable {
        let id = UUID()
        let assetIds: [String]
        let incompleteSkipped: Int
        var count: Int { assetIds.count }
    }

    func pause() {
        guard isRunning else { return }
        isPaused = true
        // Do not wait for the in-flight asset — prompt delete for everything already verified.
        if pendingDeletes.isEmpty {
            status = "Paused — finishing current asset, then holding"
        } else {
            status = "Paused — confirming delete of \(pendingDeletes.count)…"
            scheduleFlushDeletes()
        }
    }

    func resume() {
        guard isRunning else { return }
        isPaused = false
        status = "Resuming…"
    }

    /// Manual flush while paused (e.g. more assets finished after the first prompt).
    func deleteVerifiedNow() {
        guard isRunning, isPaused, !pendingDeletes.isEmpty else { return }
        status = "Paused — confirming delete of \(pendingDeletes.count)…"
        scheduleFlushDeletes()
    }

    func respondToLeftoverOffer(delete: Bool) {
        leftoverDecision?.resume(returning: delete)
        leftoverDecision = nil
        leftoverOffer = nil
    }

    /// Connect to Mac, list archive assetIds, offer delete for those still on the phone.
    func auditArchiveLeftovers(pin: String) async {
        guard !isRunning else { return }
        guard pin.count >= 4 else {
            status = "Enter PIN to audit archive"
            return
        }
        settings.lastPin = pin
        status = "Auditing archive…"
        let client = TransferClient(pin: pin, deviceName: UIDevice.current.name)
        do {
            try await client.connect()
        } catch {
            status = "Audit connect failed: \(error.localizedDescription)"
            return
        }

        let deleted = await offerDeleteForArchiveLeftovers(client: client)
        try? await client.endSession()
        if deleted > 0 {
            status = "Audit done — deleted \(deleted) leftovers"
        } else {
            status = "Audit done — no leftovers on phone"
        }
    }

    func run(pin: String) async {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        defer {
            isRunning = false
            isPaused = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        UIApplication.shared.isIdleTimerDisabled = true
        summary = ImportSummary()

        _ = await PhotoAccess.request()
        guard PhotoAccess.canImport else {
            status = "Photos access required"
            return
        }

        settings.lastPin = pin
        status = "Connecting…"
        let client = TransferClient(pin: pin, deviceName: UIDevice.current.name)
        do {
            try await client.connect()
        } catch {
            status = "Connect failed: \(error.localizedDescription)"
            return
        }

        status = "Auditing archive leftovers…"
        _ = await offerDeleteForArchiveLeftovers(client: client)

        let opts = PHFetchOptions()
        opts.includeHiddenAssets = true
        opts.includeAllBurstAssets = true
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(with: opts)
        total = fetch.count
        progress = 0

        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }

        pendingDeletes.removeAll(keepingCapacity: true)
        pendingDeleteCount = 0
        flushTask?.cancel()
        flushTask = nil

        for asset in assets {
            while isPaused {
                if !pendingDeletes.isEmpty {
                    status = "Paused — confirming delete of \(pendingDeletes.count)…"
                    await flushPendingDeletes()
                }
                status = pendingDeletes.isEmpty
                    ? "Paused at \(progress)/\(total)"
                    : "Paused — \(pendingDeletes.count) verified waiting to delete"
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            progress += 1
            status = "Asset \(progress)/\(total)"
            let settled = await transferAndSettle(asset, client: client)
            recordTransfer(settled.outcome)
            if let copy = settled.copy {
                pendingDeletes.append(copy)
                pendingDeleteCount = pendingDeletes.count
                // If user paused mid-asset, offer delete as soon as this one settles too.
                if isPaused {
                    status = "Paused — confirming delete of \(pendingDeletes.count)…"
                    scheduleFlushDeletes()
                }
            }
        }

        // Wait for any in-flight pause flush, then drain the rest at end.
        if let flushTask {
            await flushTask.value
        }
        if !pendingDeletes.isEmpty {
            status = "Confirm delete of \(pendingDeletes.count)…"
            await flushPendingDeletes()
        }

        try? await client.endSession()
        status = "Finished — deleted \(summary.deleted), retained \(summary.retained)"
    }

    private func scheduleFlushDeletes() {
        let batch = pendingDeletes
        guard !batch.isEmpty else { return }
        pendingDeletes.removeAll(keepingCapacity: true)
        pendingDeleteCount = 0
        let previous = flushTask
        flushTask = Task { @MainActor in
            // Serialize Photos prompts — don't cancel an in-flight confirmation.
            await previous?.value
            guard !Task.isCancelled else { return }
            await self.applyDeleteResults(batch)
            if self.isPaused {
                self.status = self.pendingDeletes.isEmpty
                    ? "Paused at \(self.progress)/\(self.total)"
                    : "Paused — \(self.pendingDeletes.count) verified waiting to delete"
            }
        }
    }

    private func flushPendingDeletes() async {
        let batch = pendingDeletes
        pendingDeletes.removeAll(keepingCapacity: true)
        pendingDeleteCount = 0
        guard !batch.isEmpty else { return }
        await applyDeleteResults(batch)
    }

    private func applyDeleteResults(_ batch: [VerifiedCopy]) async {
        let results = await DeletionService.deleteVerifiedBatch(batch, settings: settings)
        for copy in batch {
            let result = results[copy.assetId] ?? .retained(.failed)
            let deleted: Bool
            let reason: RetainReason?
            switch result {
            case .deleted:
                deleted = true
                reason = nil
                summary.deleted += 1
            case .retained(let r):
                deleted = false
                reason = r
                summary.retained += 1
            }
            if let idx = summary.outcomes.firstIndex(where: { $0.id == copy.assetId }) {
                summary.outcomes[idx] = AssetOutcome(
                    id: copy.assetId,
                    bytes: copy.bytes,
                    verified: true,
                    deleted: deleted,
                    retainReason: reason
                )
            }
        }
    }

    private struct SettledTransfer {
        var outcome: AssetOutcome
        /// Non-nil when verified + settled and eligible to queue for delete.
        var copy: VerifiedCopy?
    }

    /// Transfer → settle; defer delete so many assets share one Photos confirmation.
    private func transferAndSettle(
        _ asset: PHAsset,
        client: TransferClient
    ) async -> SettledTransfer {
        switch await transferVerified(asset, client: client) {
        case .failure(let reason, let bytes):
            return SettledTransfer(
                outcome: AssetOutcome(
                    id: asset.localIdentifier,
                    bytes: bytes,
                    verified: false,
                    deleted: false,
                    retainReason: reason
                ),
                copy: nil
            )
        case .success(let copy):
            do {
                _ = try await client.settleAsset(assetId: copy.assetId)
            } catch {
                return SettledTransfer(
                    outcome: AssetOutcome(
                        id: copy.assetId,
                        bytes: copy.bytes,
                        verified: true,
                        deleted: false,
                        retainReason: .settleFailed
                    ),
                    copy: nil
                )
            }
            // Placeholder until batch delete runs — counts as verified, not yet deleted/retained.
            return SettledTransfer(
                outcome: AssetOutcome(
                    id: copy.assetId,
                    bytes: copy.bytes,
                    verified: true,
                    deleted: false,
                    retainReason: nil
                ),
                copy: copy
            )
        }
    }

    /// Returns number deleted (0 if none / declined / none found).
    private func offerDeleteForArchiveLeftovers(client: TransferClient) async -> Int {
        let index: ArchiveIndexPayload
        do {
            status = "Verifying archive (sha256)…"
            index = try await client.fetchArchiveIndex()
        } catch {
            status = "Archive verify failed: \(error.localizedDescription)"
            return 0
        }

        let leftovers = Self.archivedAssetsStillOnPhone(
            archiveIds: index.assetIds,
            settings: settings
        )
        if leftovers.isEmpty {
            if index.incompleteCount > 0 {
                status = "No leftovers — \(index.incompleteCount) incomplete archive assets skipped"
            }
            return 0
        }

        let shouldDelete = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            leftoverDecision = cont
            leftoverOffer = LeftoverDeleteOffer(
                assetIds: leftovers,
                incompleteSkipped: index.incompleteCount
            )
            status = "Found \(leftovers.count) verified leftovers on phone"
        }
        guard shouldDelete else { return 0 }

        status = "Deleting \(leftovers.count) leftovers…"
        let results = await DeletionService.deleteArchivedAssetIds(leftovers, settings: settings)
        let deleted = results.values.filter {
            if case .deleted = $0 { return true }
            return false
        }.count
        summary.deleted += deleted
        return deleted
    }

    /// Archive assetIds that are still in the library and not protected.
    private static func archivedAssetsStillOnPhone(
        archiveIds: [String],
        settings: SettingsStore
    ) -> [String] {
        guard PhotoAccess.canDelete || PhotoAccess.canImport else { return [] }
        let policy = ProtectionPolicy(
            protectFavourites: settings.protectFavourites,
            protectedAlbumIds: Set(settings.protectedAlbumIds)
        )
        var out: [String] = []
        // PhotoKit accepts large identifier lists; chunk to stay safe.
        let chunkSize = 500
        var start = archiveIds.startIndex
        while start < archiveIds.endIndex {
            let end = archiveIds.index(start, offsetBy: chunkSize, limitedBy: archiveIds.endIndex)
                ?? archiveIds.endIndex
            let chunk = Array(archiveIds[start..<end])
            start = end
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
            fetch.enumerateObjects { asset, _, _ in
                let albums = ProtectionPolicy.albumIds(containing: asset)
                if policy.isProtected(asset, albumIds: albums) { return }
                out.append(asset.localIdentifier)
            }
        }
        return out
    }

    private func recordTransfer(_ outcome: AssetOutcome) {
        summary.outcomes.append(outcome)
        summary.imported += 1
        if outcome.verified {
            summary.verified += 1
            summary.bytesVerified += outcome.bytes
        } else {
            summary.failed += 1
        }
        // Pending deletes have verified=true, retainReason=nil — counted in flushDeletes.
        if !outcome.deleted && (outcome.retainReason != nil || !outcome.verified) {
            summary.retained += 1
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
