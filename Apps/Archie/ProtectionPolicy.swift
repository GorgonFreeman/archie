import ArchieCore
import Photos

struct ProtectionPolicy {
    var protectFavourites: Bool
    var protectLast30Days: Bool
    var protectedAlbumIds: Set<String>

    func isProtected(_ asset: PHAsset, albumIds: Set<String>) -> Bool {
        if isFavouriteOrAlbumProtected(asset, albumIds: albumIds) { return true }
        return isRecentProtected(asset)
    }

    func isFavouriteOrAlbumProtected(_ asset: PHAsset, albumIds: Set<String>) -> Bool {
        if protectFavourites && asset.isFavorite { return true }
        return !albumIds.isDisjoint(with: protectedAlbumIds)
    }

    /// Assets newer than the protect window stay on the phone when the toggle is on.
    func isRecentProtected(_ asset: PHAsset) -> Bool {
        protectLast30Days && RecentSeenLog.isWithinWindow(creationDate: asset.creationDate)
    }

    /// Fresh evaluation at delete time.
    static func albumIds(containing asset: PHAsset) -> Set<String> {
        let result = PHAssetCollection.fetchAssetCollectionsContaining(
            asset,
            with: .album,
            options: nil
        )
        var ids = Set<String>()
        result.enumerateObjects { collection, _, _ in
            ids.insert(collection.localIdentifier)
        }
        return ids
    }
}
