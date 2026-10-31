import Photos

enum DeleteResult: Sendable {
    case deleted
    case retained(RetainReason)
}

enum DeletionService {
    /// Deletes only a `VerifiedCopy` (all resources + sidecar receipt-matched).
    /// Re-reads protection and requires full Photos access.
    /// Callers flush on pause and at end of import (one Photos confirmation per flush).
    @MainActor
    static func deleteVerified(
        _ copy: VerifiedCopy,
        settings: SettingsStore
    ) async -> DeleteResult {
        let map = await deleteVerifiedBatch([copy], settings: settings)
        return map[copy.assetId] ?? .retained(.failed)
    }

    /// One Photos confirmation for the whole batch. Per-asset protection still applied.
    @MainActor
    static func deleteVerifiedBatch(
        _ copies: [VerifiedCopy],
        settings: SettingsStore
    ) async -> [String: DeleteResult] {
        var results: [String: DeleteResult] = [:]
        guard !copies.isEmpty else { return results }

        guard PhotoAccess.canDelete else {
            for copy in copies {
                results[copy.assetId] = .retained(.limitedAccess)
            }
            return results
        }

        let policy = ProtectionPolicy(
            protectFavourites: settings.protectFavourites,
            protectLast30Days: settings.protectLast30Days,
            protectedAlbumIds: Set(settings.protectedAlbumIds)
        )

        var toDelete: [PHAsset] = []
        var deleteIds: [String] = []

        for copy in copies {
            guard copy.receipts.contains(where: { $0.type == "sidecar" }) else {
                results[copy.assetId] = .retained(.sidecarFailed)
                continue
            }

            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [copy.assetId], options: nil)
            guard let asset = fetch.firstObject else {
                results[copy.assetId] = .deleted
                continue
            }

            let albums = ProtectionPolicy.albumIds(containing: asset)
            if policy.isFavouriteOrAlbumProtected(asset, albumIds: albums) {
                results[copy.assetId] = .retained(.protected)
                continue
            }
            if policy.isRecentProtected(asset) {
                results[copy.assetId] = .retained(.recentProtected)
                continue
            }

            toDelete.append(asset)
            deleteIds.append(copy.assetId)
        }

        guard !toDelete.isEmpty else { return results }

        // Present the system delete confirmation (requires full Photos access + at least one asset).
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
            }
        } catch {
            for id in deleteIds {
                results[id] = .retained(.deleteDeclined)
            }
            return results
        }

        for id in deleteIds {
            let still = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            results[id] = still.count == 0 ? .deleted : .retained(.deleteDeclined)
        }
        return results
    }

    /// Delete assets proven by Mac archive presence (sidecar assetId), not this-session receipts.
    @MainActor
    static func deleteArchivedAssetIds(
        _ assetIds: [String],
        settings: SettingsStore
    ) async -> [String: DeleteResult] {
        var results: [String: DeleteResult] = [:]
        guard !assetIds.isEmpty else { return results }

        guard PhotoAccess.canDelete else {
            for id in assetIds {
                results[id] = .retained(.limitedAccess)
            }
            return results
        }

        let policy = ProtectionPolicy(
            protectFavourites: settings.protectFavourites,
            protectLast30Days: settings.protectLast30Days,
            protectedAlbumIds: Set(settings.protectedAlbumIds)
        )

        var toDelete: [PHAsset] = []
        var deleteIds: [String] = []

        for id in assetIds {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard let asset = fetch.firstObject else {
                results[id] = .deleted
                continue
            }
            let albums = ProtectionPolicy.albumIds(containing: asset)
            if policy.isFavouriteOrAlbumProtected(asset, albumIds: albums) {
                results[id] = .retained(.protected)
                continue
            }
            if policy.isRecentProtected(asset) {
                results[id] = .retained(.recentProtected)
                continue
            }
            toDelete.append(asset)
            deleteIds.append(id)
        }

        guard !toDelete.isEmpty else { return results }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
            }
        } catch {
            for id in deleteIds {
                results[id] = .retained(.deleteDeclined)
            }
            return results
        }

        for id in deleteIds {
            let still = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            results[id] = still.count == 0 ? .deleted : .retained(.deleteDeclined)
        }
        return results
    }
}
