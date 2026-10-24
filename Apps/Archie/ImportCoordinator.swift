import Foundation
import Photos
import SwiftUI
import UIKit

@MainActor
final class ImportCoordinator: ObservableObject {
    @Published var status = "Idle"
    @Published var progress = 0
    @Published var total = 0
    @Published var summary = ImportSummary()
    @Published var isRunning = false
    @Published var isPaused = false
    /// Show Reconnect: mid-run link loss, or a failed setup that can start fresh.
    @Published private(set) var needsReconnect = false
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
    /// Live import session client (for resume ping / abort).
    private var activeClient: TransferClient?
    /// PIN for the current import run (reconnect uses the same PIN).
    private var sessionPin = ""
    /// Settled assetIds on the Mac — skip transfer; refreshed after reconnect.
    private var settledOnMac: Set<String> = []
    /// Pause was triggered by leaving the foreground (auto-resume on active).
    private var pausedForBackground = false
    /// Setup failed after `run` exits — keep Reconnect and restart Import from scratch.
    private var retryImportAfterFailure = false

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
        if needsReconnect {
            status = "Stopped — connection lost. Tap Reconnect (\(progress)/\(total))"
        } else if pendingDeletes.isEmpty {
            status = "Paused — finishing current asset, then holding"
        } else {
            status = "Paused — confirming delete of \(pendingDeletes.count)…"
            scheduleFlushDeletes()
        }
    }

    /// Auto-pause when backgrounded; Resume (or auto on active) reconnects if needed.
    /// Uses `.background` only — `.inactive` (Control Center) would flap mid-transfer.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            guard isRunning, !isPaused else { return }
            pausedForBackground = true
            isPaused = true
            status = "Paused — app left foreground (tap Resume to continue)"
            if !pendingDeletes.isEmpty {
                scheduleFlushDeletes()
            }
        case .active:
            guard isRunning, isPaused, pausedForBackground else { return }
            pausedForBackground = false
            resume()
        default:
            break
        }
    }

    func resume() {
        guard isRunning else { return }
        if recentMonthDecision != nil {
            continuePastRecentMonth()
            return
        }
        status = needsReconnect ? "Reconnecting…" : "Checking connection…"
        Task { await resumeAfterConnectionCheck() }
    }

    /// Mid-run reconnect, or a fresh Import after a setup/connect failure.
    func reconnect(pin: String) {
        if isRunning {
            resume()
            return
        }
        guard !isScanning else { return }
        let usePin = pin.count >= 4 ? pin : (sessionPin.isEmpty ? settings.lastPin : sessionPin)
        guard usePin.count >= 4 else {
            status = "Enter PIN to reconnect"
            return
        }
        needsReconnect = false
        retryImportAfterFailure = false
        status = "Reconnecting…"
        Task { await run(pin: usePin) }
    }

    /// Leave Reconnect visible after `run` returns so the user can start fresh.
    private func offerFreshReconnect(_ message: String) {
        retryImportAfterFailure = true
        needsReconnect = true
        isPaused = false
        status = "\(message). Tap Reconnect"
    }

    private func resumeAfterConnectionCheck() async {
        guard isRunning, isPaused else { return }
        if let client = activeClient, client.isAlive {
            do {
                try await client.ping()
                needsReconnect = false
                isPaused = false
                status = "Resuming…"
                return
            } catch {
                // Fall through to Bonjour reconnect.
            }
        }
        status = "Reconnecting…"
        do {
            let client: TransferClient
            if let existing = activeClient {
                try await existing.reconnect()
                client = existing
            } else {
                guard !sessionPin.isEmpty else {
                    needsReconnect = true
                    status = "Reconnect failed — missing PIN"
                    return
                }
                client = TransferClient(pin: sessionPin, deviceName: UIDevice.current.name)
                try await client.connect()
                activeClient = client
            }
            if let refreshed = try? await client.fetchSettledIds() {
                settledOnMac = refreshed
            }
            needsReconnect = false
            isPaused = false
            status = "Resuming…"
        } catch {
            needsReconnect = true
            isPaused = true
            status = "Reconnect failed — tap Reconnect when Mac is ready"
        }
    }

    private func enterConnectionLostWait() {
        needsReconnect = true
        isPaused = true
        pausedForBackground = false
        status = "Stopped — connection lost. Tap Reconnect (\(progress)/\(total))"
    }

    /// Delete whatever is verified and ready (import queue and/or leftover scan).
    func deleteVerified() {
        guard verifiedReadyCount > 0 else { return }
        if isDeletingVerified {
            status = "Delete already in progress…"
            return
        }
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
        needsReconnect = false
        retryImportAfterFailure = false
        pausedForBackground = false
        sessionPin = pin
        settledOnMac = []
        defer {
            let keepRetry = retryImportAfterFailure
            isRunning = false
            isPaused = false
            pausedForBackground = false
            activeClient = nil
            settledOnMac = []
            UIApplication.shared.isIdleTimerDisabled = false
            if keepRetry {
                // Keep sessionPin + Reconnect so the user can start fresh.
                needsReconnect = true
            } else {
                needsReconnect = false
                sessionPin = ""
            }
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
            offerFreshReconnect("Connect failed: \(error.localizedDescription)")
            return
        }
        activeClient = client

        status = "Loading settled archive IDs…"
        do {
            settledOnMac = try await client.fetchSettledIds()
        } catch {
            // Optional optimization — if the link is still up, continue without skip.
            // If the Mac session died (e.g. old receiver), offer Reconnect to start fresh.
            if Self.isConnectionLost(error) || !client.isAlive {
                try? await client.endSession()
                offerFreshReconnect(
                    "Settled IDs failed (is Mac receiver up to date?): \(error.localizedDescription)"
                )
                return
            }
            settledOnMac = []
            status = "Settled IDs unavailable — continuing without skip…"
        }

        status = "Loading protected-seen log…"
        let protectedSeen: Set<String>
        do {
            protectedSeen = try await client.fetchProtectedSeen()
        } catch {
            try? await client.endSession()
            offerFreshReconnect("Protected-seen log failed: \(error.localizedDescription)")
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
        var skippedSettled = 0
        let settledSnapshot = settledOnMac
        fetch.enumerateObjects { asset, _, _ in
            if settledSnapshot.contains(asset.localIdentifier) {
                skippedSettled += 1
                return
            }
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
        var skipNotes: [String] = []
        if skippedSettled > 0 {
            skipNotes.append("\(skippedSettled) already on Mac")
        }
        if skippedProtectedSeen > 0 {
            skipNotes.append("\(skippedProtectedSeen) protected-seen")
        }
        if !skipNotes.isEmpty {
            status = "Skipping \(skipNotes.joined(separator: ", "))…"
        }

        pendingDeletes.removeAll(keepingCapacity: true)
        publishVerifiedReadyCount()
        flushTask?.cancel()
        flushTask = nil

        let recentMonthStart = Self.startOfNewestMonth(in: assets)
        var offeredRecentMonthGate = false

        var index = 0
        while index < assets.count {
            // Hold here while paused or until Resume reconnects a dead link.
            while isPaused || activeClient == nil || !(activeClient?.isAlive ?? false) {
                if activeClient == nil || !(activeClient?.isAlive ?? false) {
                    enterConnectionLostWait()
                }
                while isPaused {
                    if needsReconnect {
                        status = "Stopped — connection lost. Tap Reconnect (\(progress)/\(total))"
                    } else {
                        status = pendingDeletes.isEmpty
                            ? "Paused at \(progress)/\(total)"
                            : "Paused — \(pendingDeletes.count) verified waiting to delete"
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            guard let client = activeClient, client.isAlive else { continue }

            let asset = assets[index]
            if settledOnMac.contains(asset.localIdentifier) {
                index += 1
                progress = index
                continue
            }

            if !offeredRecentMonthGate,
               let recentMonthStart,
               let created = asset.creationDate,
               created >= recentMonthStart {
                offeredRecentMonthGate = true
                await pauseForRecentMonth(monthStart: recentMonthStart)
                // User may have backgrounded / lost link during the gate.
                continue
            }

            progress = index + 1
            status = "Asset \(progress)/\(total)"
            let settled = await transferAndSettle(
                asset,
                client: client,
                protection: protection,
                protectedByAlbum: protectedByAlbum
            )
            if case .connectionLost = settled {
                enterConnectionLostWait()
                continue // retry same asset after reconnect
            }
            if case .ok(let outcome, let copy) = settled {
                settledOnMac.insert(asset.localIdentifier)
                recordTransfer(outcome)
                if let copy {
                    pendingDeletes.append(copy)
                    publishVerifiedReadyCount()
                    // If user paused mid-asset, offer delete as soon as this one settles too.
                    if isPaused {
                        status = "Paused — confirming delete of \(pendingDeletes.count)…"
                        scheduleFlushDeletes()
                    }
                }
            }
            index += 1
        }

        // Wait for any in-flight pause flush, then drain the rest at end.
        if let flushTask {
            await flushTask.value
        }
        if !pendingDeletes.isEmpty {
            status = "Confirm delete of \(pendingDeletes.count)…"
            await flushPendingDeletes()
        }

        try? await activeClient?.endSession()
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
        pendingDeletes = []
        publishVerifiedReadyCount()
        guard !batch.isEmpty else { return }
        await applyDeleteResults(batch)
    }

    private func flushAllVerifiedReady() async {
        guard !isDeletingVerified else { return }
        isDeletingVerified = true
        defer { isDeletingVerified = false }

        let importCount = pendingDeletes.count
        let leftoverCount = leftoverReadyIds.count
        let total = importCount + leftoverCount
        guard total > 0 else {
            status = "Nothing verified to delete"
            return
        }

        status = "Deleting \(total) verified…"
        if !pendingDeletes.isEmpty {
            await flushPendingDeletes()
        }
        if !leftoverReadyIds.isEmpty {
            _ = await flushLeftoverReadyDeletes()
        }

        let remaining = pendingDeletes.count + leftoverReadyIds.count
        if remaining == 0 {
            status = "Deleted verified assets"
        } else if remaining == total {
            // Nothing removed — usually all protected / limited Photos access / declined.
            if !PhotoAccess.canDelete {
                status = "Full Photos access required to delete"
            } else {
                status = "Nothing deleted — \(remaining) retained (protected or declined)"
            }
        } else {
            status = "Deleted some — \(remaining) still ready"
        }
    }

    private func applyDeleteResults(_ batch: [VerifiedCopy]) async {
        let results = await DeletionService.deleteVerifiedBatch(batch, settings: settings)
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
                // Protected / gone-from-library should leave the delete queue.
                // Declined / limited / failed stay so Delete Verified can retry.
                switch r {
                case .protected, .sidecarFailed:
                    break
                case .deleteDeclined, .limitedAccess, .failed, .unreadable, .settleFailed:
                    keep.append(copy)
                }
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

        // Anything verified while the Photos prompt was up stays queued.
        pendingDeletes.append(contentsOf: keep)
        publishVerifiedReadyCount()
    }

    private enum SettledTransfer {
        case ok(AssetOutcome, copy: VerifiedCopy?)
        case connectionLost
    }

    /// Transfer → settle; defer delete so many assets share one Photos confirmation.
    private func transferAndSettle(
        _ asset: PHAsset,
        client: TransferClient,
        protection: ProtectionPolicy,
        protectedByAlbum: Set<String>
    ) async -> SettledTransfer {
        switch await transferVerified(asset, client: client) {
        case .connectionLost:
            return .connectionLost
        case .failure(let reason, let bytes):
            return .ok(
                AssetOutcome(
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
                if Self.isConnectionLost(error) || !client.isAlive {
                    return .connectionLost
                }
                return .ok(
                    AssetOutcome(
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
                // Keep on phone — do not queue for Delete Verified (would never show a Photos prompt).
                try? await client.markProtectedSeen(assetId: copy.assetId)
                return .ok(
                    AssetOutcome(
                        id: copy.assetId,
                        bytes: copy.bytes,
                        verified: true,
                        deleted: false,
                        retainReason: .protected
                    ),
                    copy: nil
                )
            }
            // Placeholder until batch delete runs — counts as verified, not yet deleted/retained.
            return .ok(
                AssetOutcome(
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

    private static func isConnectionLost(_ error: Error) -> Bool {
        if let transfer = error as? TransferError { return transfer.isConnectionLost }
        return false
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
            switch results[id] {
            case .deleted:
                deleted += 1
            case .retained(.deleteDeclined), .retained(.limitedAccess), .retained(.failed), .none:
                // Retryable — keep in the Delete Verified queue.
                remaining.append(id)
            case .retained:
                // Protected / already gone from deletable set — drop from queue.
                break
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
        case connectionLost
    }

    /// Returns `VerifiedCopy` only when every media resource and the sidecar have matching RECEIPTs.
    private func transferVerified(
        _ asset: PHAsset,
        client: TransferClient
    ) async -> TransferResult {
        guard client.isAlive else { return .connectionLost }
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
                if Self.isConnectionLost(error) || !client.isAlive {
                    return .connectionLost
                }
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
            if Self.isConnectionLost(error) || !client.isAlive {
                return .connectionLost
            }
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
                if Self.isConnectionLost(error) || !client.isAlive {
                    throw error
                }
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
