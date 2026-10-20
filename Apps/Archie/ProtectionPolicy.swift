import Photos

struct ProtectionPolicy {
    var protectFavourites: Bool
    var protectedAlbumIds: Set<String>

    func isProtected(_ asset: PHAsset, albumIds: Set<String>) -> Bool {
        if protectFavourites && asset.isFavorite { return true }
        return !albumIds.isDisjoint(with: protectedAlbumIds)
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
