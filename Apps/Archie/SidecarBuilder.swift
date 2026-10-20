import Photos
import UIKit

enum SidecarBuilder {
    static func build(
        asset: PHAsset,
        resources: [SidecarResource]
    ) -> SidecarDocument {
        let albums = fetchAlbums(for: asset)
        var location: SidecarLocation?
        if let loc = asset.location {
            location = SidecarLocation(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil
            )
        }

        return SidecarDocument(
            assetId: asset.localIdentifier,
            deviceModel: UIDevice.current.model,
            iosVersion: UIDevice.current.systemVersion,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            location: location,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            albums: albums,
            mediaType: mediaTypeName(asset.mediaType),
            subtypes: subtypeNames(asset.mediaSubtypes),
            burstIdentifier: asset.burstIdentifier,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            resources: resources
        )
    }

    private static func fetchAlbums(for asset: PHAsset) -> [SidecarAlbum] {
        let result = PHAssetCollection.fetchAssetCollectionsContaining(
            asset,
            with: .album,
            options: nil
        )
        var albums: [SidecarAlbum] = []
        result.enumerateObjects { collection, _, _ in
            albums.append(SidecarAlbum(
                name: collection.localizedTitle ?? "",
                localIdentifier: collection.localIdentifier
            ))
        }
        return albums
    }

    private static func mediaTypeName(_ type: PHAssetMediaType) -> String {
        switch type {
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        default: return "unknown"
        }
    }

    private static func subtypeNames(_ subtypes: PHAssetMediaSubtype) -> [String] {
        var names: [String] = []
        let map: [(PHAssetMediaSubtype, String)] = [
            (.photoPanorama, "photoPanorama"),
            (.photoHDR, "photoHDR"),
            (.photoScreenshot, "photoScreenshot"),
            (.photoLive, "photoLive"),
            (.photoDepthEffect, "photoDepthEffect"),
            (.videoStreamed, "videoStreamed"),
            (.videoHighFrameRate, "videoHighFrameRate"),
            (.videoTimelapse, "videoTimelapse"),
            (.videoCinematic, "videoCinematic"),
        ]
        for (flag, name) in map where subtypes.contains(flag) {
            names.append(name)
        }
        return names
    }
}
