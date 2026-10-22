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
    /// True while Mac is streaming archive SHA-256 verification (Scan leftovers).
    @Published private(set) var isScanning = false
    @Published private(set) var scanScanned = 0
    @Published private(set) var scanTotal = 0
    /// Leftovers from Scan still on the phone (drives Scan leftovers (N)).
    @Published private(set) var leftoverReadyCount = 0
    /// Import queue + leftover queue — drives Delete Verified.
    @Published private(set) var verifiedReadyCount = 0
    /// Soft stop before importing the newest calendar month (favorite first).
    @Published var recentMonthOffer: RecentMonthOffer?

    private let settings: SettingsStore
    /// Import path: verified+settled copies waiting for Photos delete.
    private var pendingDeletes: [VerifiedCopy] = []
    private var flushTask: Task<Void, Never>?
    private var recentMonthDecision: CheckedContinuation<Void, Never>?
    /// Leftover-scan path: archive-verified asset IDs still on the phone.
    private var leftoverReadyIds: [String] = []
    private var scanIncompleteSkipped = 0
    private var isDeletingVerified = false

    init(settings: SettingsStore) {
        self.settings = settings
    }

    struct RecentMonthOffer: Identifiable {
        let id = UUID()
        let monthLabel: String
    }

    private func publishVerifiedReadyCount() {
        leftoverReadyCount = leftoverReadyIds.count
        verifiedReadyCount = pendingDeletes.count + leftoverReadyIds.count
    }

    func pause() {
        guard isRunning else { return }
        isPaused = true
        // Offer delete for everything already verified (Photos confirmation).
        // Queue is only drained for assets that actually delete — declined stay ready.
        if pendingDeletes.isEmpty {
            status = "Paused — finishing current asset, then holding"
        } else {
            status = "Paused — confirming delete of \(pendingDeletes.count)…"
            scheduleFlushDeletes()
        }
    }

    func resume() {
        guard isRunning else { return }
        if recentMonthDecision != nil {
            continuePastRecentMonth()
            return
        }
        isPaused = false
        status = "Resuming…"
    }

    /// Delete whatever is verified and ready (import queue and/or leftover scan).
    func deleteVerified() {
        guard verifiedReadyCount > 0, !isDeletingVerified else { return }
        Task { await flushAllVerifiedReady() }
    }

    /// Continue past the newest-month gate (after favouriting).
    func continuePastRecentMonth() {
        recentMonthDecision?.resume()
        recentMonthDecision = nil
        recentMonthOffer = nil
        if isRunning {
            isPaused = false
            status = "Resuming recent month…"
        }
    }

    /// Verify Mac archive (SHA-256) and accumulate phone leftovers for Delete Verified.
    func scanLeftovers(pin: String) async {
        guard !isRunning, !isScanning else { return }
        guard pin.count >= 4 else {
            status = "Enter PIN to scan leftovers"
            return
        }
        settings.lastPin = pin
        clearLeftoverQueue()
        isScanning = true
        scanScanned = 0
        scanTotal = 0
        scanIncompleteSkipped = 0
        defer { isScanning = false }

        status = "Connecting to scan leftovers…"
        let client = TransferClient(pin: pin, deviceName: UIDevice.current.name)
        do {
            try await client.connect()
        } catch {
            status = "Scan connect failed: \(error.localizedDescription)"
            return
        }

        do {
            status = "Verifying archive…"
            try await client.streamArchiveIndex { progress in
                await self.applyScanProgress(progress)
            }
        } catch {
            status = "Archive verify failed: \(error.localizedDescription)"
            try? await client.endSession()
            return
        }

        try? await client.endSession()
        let ready = leftoverReadyIds.count
        if ready > 0 {
            status = "Scan done — \(ready) leftovers ready to delete"
        } else if scanIncompleteSkipped > 0 {
            status = "Scan done — no leftovers (\(scanIncompleteSkipped) incomplete skipped)"
        } else {
            status = "Scan done — no leftovers on phone"
        }
    }

    /// Import phone library to Mac. Does not scan leftovers first.
    func run(pin: String) async {
        guard !isRunning, !isScanning else { return }
        isRunning = true
        isPaused = false
        defer {
            isRunning = false
            isPaused = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        UIApplication.shared.isIdleTimerDisabled = true
        summary = ImportSummary()
        // Do not clear leftover queue — Scan leftovers is independent of Import.

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

        status = "Loading protected-seen log…"
        let protectedSeen: Set<String>
        do {
            protectedSeen = try await client.fetchProtectedSeen()
        } catch {
            status = "Protected-seen log failed: \(error.localizedDescription)"
            try? await client.endSession()
            return
        }

        let protection = ProtectionPolicy(
            protectFavourites: settings.protectFavourites,
            protectedAlbumIds: Set(settings.protectedAlbumIds)
        )
        let protectedByAlbum = Self.assetIdsInProtectedAlbums(settings: settings)

        let opts = PHFetchOptions()
        opts.includeHiddenAssets = true
        opts.includeAllBurstAssets = true
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(with: opts)

        var assets: [PHAsset] = []
        var skippedProtectedSeen = 0
        fetch.enumerateObjects { asset, _, _ in
            let protectedNow = Self.isProtected(
                asset,
                policy: protection,
                protectedByAlbum: protectedByAlbum
            )
            if protectedNow && protectedSeen.contains(asset.localIdentifier) {
                skippedProtectedSeen += 1
                return
            }
            assets.append(asset)
        }
        total = assets.count
        progress = 0
        if skippedProtectedSeen > 0 {
            status = "Skipping \(skippedProtectedSeen) already-imported protected assets…"
        }

        pendingDeletes.removeAll(keepingCapacity: true)
        publishVerifiedReadyCount()
        flushTask?.cancel()
        flushTask = nil

        let recentMonthStart = Self.startOfNewestMonth(in: assets)
        var offeredRecentMonthGate = false

        for asset in assets {
            if !offeredRecentMonthGate,
               let recentMonthStart,
               let created = asset.creationDate,
               created >= recentMonthStart {
                offeredRecentMonthGate = true
                await pauseForRecentMonth(monthStart: recentMonthStart)
            }
            while isPaused {
                // Flush is scheduled once on pause / when the in-flight asset settles.
                // Do not re-flush every tick — that races the Photos prompt and drops the queue.
                status = pendingDeletes.isEmpty
                    ? "Paused at \(progress)/\(total)"
                    : "Paused — \(pendingDeletes.count) verified waiting to delete"
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            progress += 1
            status = "Asset \(progress)/\(total)"
            let settled = await transferAndSettle(
                asset,
                client: client,
                protection: protection,
                protectedByAlbum: protectedByAlbum
            )
            recordTransfer(settled.outcome)
            if let copy = settled.copy {
                pendingDeletes.append(copy)
                publishVerifiedReadyCount()
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
        if pendingDeletes.count + leftoverReadyIds.count > 0 {
            let n = pendingDeletes.count + leftoverReadyIds.count
            status = "Finished — \(n) verified still ready to delete"
        } else {
            status = "Finished — deleted \(summary.deleted), retained \(summary.retained)"
        }
    }

    /// First calendar month that contains the newest asset — pause before importing it.
    private static func startOfNewestMonth(in assets: [PHAsset]) -> Date? {
        guard let newest = assets.compactMap(\.creationDate).max() else { return nil }
        let cal = Calendar.current
        let parts = cal.dateComponents([.year, .month], from: newest)
        return cal.date(from: parts)
    }

    private static func monthLabel(for monthStart: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: monthStart)
    }

    private func pauseForRecentMonth(monthStart: Date) async {
        let label = Self.monthLabel(for: monthStart)
        isPaused = true
        if !pendingDeletes.isEmpty {
            status = "Paused — confirming delete of \(pendingDeletes.count)…"
            await flushPendingDeletes()
        }
        status = "Paused — reached \(label); favourite then continue"
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            recentMonthDecision = cont
            recentMonthOffer = RecentMonthOffer(monthLabel: label)
        }
    }

    private func clearLeftoverQueue() {
        leftoverReadyIds = []
        publishVerifiedReadyCount()
    }

    private func scheduleFlushDeletes() {
        guard !pendingDeletes.isEmpty else { return }
        let previous = flushTask
        flushTask = Task { @MainActor in
            // Serialize Photos prompts — don't cancel an in-flight confirmation.
            await previous?.value
            guard !Task.isCancelled else { return }
            guard !self.isDeletingVerified else { return }
            self.isDeletingVerified = true
            defer { self.isDeletingVerified = false }
            await self.flushPendingDeletes()
            if self.isPaused {
                self.status = self.pendingDeletes.isEmpty
                    ? "Paused at \(self.progress)/\(self.total)"
                    : "Paused — \(self.pendingDeletes.count) verified waiting to delete"
            } else if self.isRunning {
                let pending = self.pendingDeletes.count
                self.status = pending > 0
                    ? "Asset \(self.progress)/\(self.total) — \(pending) verified ready"
                    : "Asset \(self.progress)/\(self.total)"
            } else if self.pendingDeletes.count > 0 {
                self.status = "\(self.pendingDeletes.count) verified ready to delete"
            }
        }
    }

    private func flushPendingDeletes() async {
        let batch = pendingDeletes
        guard !batch.isEmpty else { return }
        await applyDeleteResults(batch)
    }

    private func flushAllVerifiedReady() async {
        guard !isDeletingVerified else { return }
        isDeletingVerified = true
        defer { isDeletingVerified = false }

        if !pendingDeletes.isEmpty {
            status = isPaused
                ? "Paused — confirming delete of \(pendingDeletes.count)…"
                : "Deleting \(pendingDeletes.count) verified…"
            await flushPendingDeletes()
        }
        if !leftoverReadyIds.isEmpty {
            _ = await flushLeftoverReadyDeletes()
        }
    }

    private func applyDeleteResults(_ batch: [VerifiedCopy]) async {
        let results = await DeletionService.deleteVerifiedBatch(batch, settings: settings)
        let batchIds = Set(batch.map(\.assetId))
        var keep: [VerifiedCopy] = []

        for copy in batch {
            let result = results[copy.assetId] ?? .retained(.failed)
            let deleted: Bool
            let reason: RetainReason?
            switch result {
            case .deleted:
                deleted = true
                reason = nil
                summary.deleted += 1
                if let idx = summary.outcomes.firstIndex(where: { $0.id == copy.assetId }) {
                    let prev = summary.outcomes[idx]
                    // Was previously counted as retained (e.g. user declined earlier) — undo.
                    if prev.retainReason != nil {
                        summary.retained = max(0, summary.retained - 1)
                    }
                }
            case .retained(let r):
                deleted = false
                reason = r
                keep.append(copy)
                if let idx = summary.outcomes.firstIndex(where: { $0.id == copy.assetId }) {
                    let prev = summary.outcomes[idx]
                    // Count retained only on first transition so retries do not inflate the total.
                    if prev.retainReason == nil {
                        summary.retained += 1
                    }
                } else {
                    summary.retained += 1
                }
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

        // Keep non-batch items + anything not successfully deleted (user can tap Delete Verified again).
        let others = pendingDeletes.filter { !batchIds.contains($0.assetId) }
        pendingDeletes = others + keep
        publishVerifiedReadyCount()
    }

    private struct SettledTransfer {
        var outcome: AssetOutcome
        /// Non-nil when verified + settled and eligible to queue for delete.
        var copy: VerifiedCopy?
    }

    /// Transfer → settle; defer delete so many assets share one Photos confirmation.
    private func transferAndSettle(
        _ asset: PHAsset,
        client: TransferClient,
        protection: ProtectionPolicy,
        protectedByAlbum: Set<String>
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
            if Self.isProtected(asset, policy: protection, protectedByAlbum: protectedByAlbum) {
                // Best-effort: skip on next import while still protected on phone.
                try? await client.markProtectedSeen(assetId: copy.assetId)
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

    private static func isProtected(
        _ asset: PHAsset,
        policy: ProtectionPolicy,
        protectedByAlbum: Set<String>
    ) -> Bool {
        if policy.protectFavourites && asset.isFavorite { return true }
        return protectedByAlbum.contains(asset.localIdentifier)
    }

    private static func assetIdsInProtectedAlbums(settings: SettingsStore) -> Set<String> {
        let albumIds = settings.protectedAlbumIds
        guard !albumIds.isEmpty else { return [] }
        var out = Set<String>()
        for albumId in albumIds {
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumId],
                options: nil
            )
            guard let collection = collections.firstObject else { continue }
            let fetch = PHAsset.fetchAssets(in: collection, options: nil)
            fetch.enumerateObjects { asset, _, _ in
                out.insert(asset.localIdentifier)
            }
        }
        return out
    }

    private func applyScanProgress(_ progress: ArchiveIndexProgressPayload) {
        let onPhone = Self.archivedAssetsStillOnPhone(
            archiveIds: progress.completeAssetIds,
            settings: settings
        )
        scanScanned = progress.scanned
        scanTotal = progress.total
        scanIncompleteSkipped = progress.incompleteCount
        if !onPhone.isEmpty {
            leftoverReadyIds.append(contentsOf: onPhone)
            publishVerifiedReadyCount()
        }
        let ready = leftoverReadyIds.count
        let readyNote = ready > 0 ? " — \(ready) ready to delete" : ""
        status = "Verifying archive \(progress.scanned)/\(progress.total)\(readyNote)"
    }

    private func flushLeftoverReadyDeletes() async -> Int {
        let ids = leftoverReadyIds
        guard !ids.isEmpty else { return 0 }

        status = "Deleting \(ids.count) verified leftovers…"
        let results = await DeletionService.deleteArchivedAssetIds(ids, settings: settings)
        var remaining: [String] = []
        var deleted = 0
        for id in ids {
            if case .deleted = results[id] {
                deleted += 1
            } else {
                // Declined / protected / failed — keep ready so Delete Verified stays usable.
                remaining.append(id)
            }
        }
        leftoverReadyIds = remaining
        publishVerifiedReadyCount()
        summary.deleted += deleted
        if isScanning {
            status = "Verifying archive \(scanScanned)/\(scanTotal) — deleted \(deleted)"
        } else if remaining.isEmpty {
            status = "Deleted \(deleted) leftovers"
        } else {
            status = "Deleted \(deleted) leftovers — \(remaining.count) still ready"
        }
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
