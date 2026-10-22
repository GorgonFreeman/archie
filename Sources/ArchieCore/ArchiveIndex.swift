import Foundation

public struct ArchiveIndexProgress: Sendable {
    public var scanned: Int
    public var total: Int
    public var incompleteCount: Int
    /// Newly verified-complete assetIds since the previous progress event (delta).
    public var completeAssetIds: [String]
    public var finished: Bool

    public init(
        scanned: Int,
        total: Int,
        incompleteCount: Int,
        completeAssetIds: [String],
        finished: Bool
    ) {
        self.scanned = scanned
        self.total = total
        self.incompleteCount = incompleteCount
        self.completeAssetIds = completeAssetIds
        self.finished = finished
    }
}

/// Asset IDs present in the archive, derived from sidecars — only after byte verification.
public enum ArchiveIndex {
    /// Low-memory streaming verify: one sidecar at a time, progress deltas, no giant retained ID list.
    public static func verifyStream(
        archiveRoot: URL,
        progressEvery: Int = 15
    ) -> AsyncStream<ArchiveIndexProgress> {
        AsyncStream { continuation in
            Task.detached(priority: .utility) {
                let sidecars = listSidecarURLs(in: archiveRoot)
                let total = sidecars.count
                var scanned = 0
                var incomplete = 0
                var batch: [String] = []
                batch.reserveCapacity(progressEvery)

                func emit(finished: Bool) {
                    continuation.yield(ArchiveIndexProgress(
                        scanned: scanned,
                        total: total,
                        incompleteCount: incomplete,
                        completeAssetIds: batch,
                        finished: finished
                    ))
                    batch.removeAll(keepingCapacity: true)
                }

                if total == 0 {
                    emit(finished: true)
                    continuation.finish()
                    return
                }

                for url in sidecars {
                    autoreleasepool {
                        scanned += 1
                        guard let data = try? Data(contentsOf: url),
                              let doc = try? MessageCodec.decode(SidecarDocument.self, from: data),
                              !doc.assetId.isEmpty else {
                            incomplete += 1
                            return
                        }
                        if isComplete(doc: doc, archiveRoot: archiveRoot) {
                            batch.append(doc.assetId)
                        } else {
                            incomplete += 1
                        }
                    }
                    let shouldEmit = batch.count >= progressEvery
                        || scanned == total
                        || scanned % progressEvery == 0
                    if shouldEmit {
                        emit(finished: scanned == total)
                    }
                }
                if !batch.isEmpty || scanned < total {
                    scanned = max(scanned, total)
                    emit(finished: true)
                }
                continuation.finish()
            }
        }
    }

    /// Every resource in the sidecar must exist on disk with a matching SHA-256.
    public static func isComplete(doc: SidecarDocument, archiveRoot: URL) -> Bool {
        let resources = doc.resources
        guard !resources.isEmpty else { return false }

        for r in resources {
            let rel = r.relativePath
            guard !rel.isEmpty, !r.sha256.isEmpty else { return false }
            let file = archiveRoot.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: file.path) else { return false }
            guard let dig = try? Sha256Hasher.hash(fileAt: file) else { return false }
            guard dig == r.sha256.lowercased() else { return false }
            if r.size > 0 {
                let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                if let n = attrs?[.size] as? NSNumber, n.int64Value != r.size {
                    return false
                }
            }
        }
        return true
    }

    private static func listSidecarURLs(in archiveRoot: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: archiveRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in enumerator {
            if nameContainsSidecar(url.lastPathComponent) {
                out.append(url)
            }
        }
        return out
    }

    private static func nameContainsSidecar(_ name: String) -> Bool {
        if name.hasSuffix(ArchieConstants.sidecarSuffix) { return true }
        return name.range(of: #"\.asset(-\d+)?\.json$"#, options: .regularExpression) != nil
    }
}
