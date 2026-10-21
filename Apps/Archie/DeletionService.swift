import Photos

enum DeleteResult: Sendable {
    case deleted
    case retained(RetainReason)
}

enum DeletionService {
    /// Max assets per `deleteAssets` call. iOS shows one confirmation per call;
    /// batching cuts prompts without waiting until the whole import ends.
    static let deleteBatchSize = 500

    /// Deletes only a `VerifiedCopy` (all resources + sidecar receipt-matched).
    /// Re-reads protection and requires full Photos access.
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
            if policy.isProtected(asset, albumIds: albums) {
                results[copy.assetId] = .retained(.protected)
                continue
            }

            toDelete.append(asset)
            deleteIds.append(copy.assetId)
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
