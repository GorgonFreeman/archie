import Foundation
import Photos

struct ExportedResource {
    var typeName: String
    var originalFilename: String
    var size: Int64
    var sha256: String
    var fileURL: URL
}

enum ResourceExporter {
    /// Streams each PHAssetResource to a temp file while hashing (no re-encode).
    /// Skips Live Photo paired videos — archive keeps the still only.
    static func exportAll(for asset: PHAsset) async throws -> [ExportedResource] {
        var out: [ExportedResource] = []
        for resource in PHAssetResource.assetResources(for: asset) {
            if isLivePhotoPairedVideo(resource.type) { continue }
            out.append(try await exportOne(resource))
        }
        return out
    }

    private static func isLivePhotoPairedVideo(_ type: PHAssetResourceType) -> Bool {
        switch type {
        case .pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo:
            return true
        default:
            return false
        }
    }

    private static func exportOne(_ resource: PHAssetResource) async throws -> ExportedResource {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("archie-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        let hasher = Sha256Hasher()
        var size: Int64 = 0

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                hasher.update(data)
                size += Int64(data.count)
                try? handle.write(contentsOf: data)
            } completionHandler: { error in
                try? handle.close()
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }

        let name = resource.originalFilename.isEmpty
            ? "resource-\(resource.type.rawValue)"
            : resource.originalFilename

        return ExportedResource(
            typeName: typeName(resource.type),
            originalFilename: name,
            size: size,
            sha256: hasher.finalize(),
            fileURL: tmp
        )
    }

    static func typeName(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .alternatePhoto: return "alternatePhoto"
        case .fullSizePhoto: return "fullSizePhoto"
        case .fullSizeVideo: return "fullSizeVideo"
        case .adjustmentData: return "adjustmentData"
        case .adjustmentBasePhoto: return "adjustmentBasePhoto"
        case .pairedVideo: return "pairedVideo"
        case .fullSizePairedVideo: return "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: return "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: return "adjustmentBaseVideo"
        default: return "resource-\(type.rawValue)"
        }
    }
}
