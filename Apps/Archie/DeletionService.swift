import Photos

enum DeleteResult: Sendable {
    case deleted
    case retained(RetainReason)
}

enum DeletionService {
    /// Deletes only a `VerifiedCopy` (all resources + sidecar receipt-matched).
    /// Re-reads protection and requires full Photos access.
    @MainActor
    static func deleteVerified(
        _ copy: VerifiedCopy,
        settings: SettingsStore
    ) async -> DeleteResult {
        // Belt: refuse anything that somehow lacks a sidecar receipt.
        guard copy.receipts.contains(where: { $0.type == "sidecar" }) else {
            return .retained(.sidecarFailed)
        }
        guard PhotoAccess.canDelete else {
            return .retained(.limitedAccess)
        }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [copy.assetId], options: nil)
        guard let asset = fetch.firstObject else {
            // Already gone — treat as success (nothing left to delete).
            return .deleted
        }

        let policy = ProtectionPolicy(
            protectFavourites: settings.protectFavourites,
            protectedAlbumIds: Set(settings.protectedAlbumIds)
        )
        let albums = ProtectionPolicy.albumIds(containing: asset)
        if policy.isProtected(asset, albumIds: albums) {
            return .retained(.protected)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }
        } catch {
            return .retained(.deleteDeclined)
        }

        let still = PHAsset.fetchAssets(withLocalIdentifiers: [copy.assetId], options: nil)
        return still.count == 0 ? .deleted : .retained(.deleteDeclined)
    }
}
