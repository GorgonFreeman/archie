import Photos

enum DeletionService {
    /// Re-evaluates protection fresh, requires full Photos access.
    @MainActor
    static func deleteEligible(
        outcomes: [AssetOutcome],
        settings: SettingsStore,
        batchSize: Int = 40
    ) async throws -> Int {
        guard PhotoAccess.canDelete else {
            throw DeleteError.limitedAccess
        }

        let policy = ProtectionPolicy(
            protectFavourites: settings.protectFavourites,
            protectedAlbumIds: Set(settings.protectedAlbumIds)
        )

        var toDelete: [PHAsset] = []
        for outcome in outcomes where outcome.verified && outcome.retainReason == nil {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [outcome.id], options: nil)
            guard let asset = fetch.firstObject else { continue }
            let albums = ProtectionPolicy.albumIds(containing: asset)
            if policy.isProtected(asset, albumIds: albums) { continue }
            toDelete.append(asset)
        }

        var deleted = 0
        for batchStart in stride(from: 0, to: toDelete.count, by: batchSize) {
            let end = min(batchStart + batchSize, toDelete.count)
            let batch = Array(toDelete[batchStart..<end])
            let ids = batch.map(\.localIdentifier)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(batch as NSArray)
            }
            let still = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            deleted += batch.count - still.count
        }
        return deleted
    }
}

enum DeleteError: Error, LocalizedError {
    case limitedAccess

    var errorDescription: String? {
        "Full Photos access required to delete"
    }
}
