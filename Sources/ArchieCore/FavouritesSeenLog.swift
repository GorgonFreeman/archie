import Foundation

/// Append-only log of favourite asset IDs that verified as transferred.
/// Lives at `<archive>/.favourites_seen_log` (one assetId per line).
public enum FavouritesSeenLog {
    public static func url(in archiveRoot: URL) -> URL {
        archiveRoot.appendingPathComponent(ArchieConstants.favouritesSeenLogName)
    }

    public static func load(archiveRoot: URL) -> Set<String> {
        let path = url(in: archiveRoot)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var out = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let id = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { out.insert(id) }
        }
        return out
    }

    /// Record a verified favourite. Idempotent.
    public static func record(assetId: String, archiveRoot: URL) throws {
        let id = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        try ArchiveLock.withLock(archiveRoot: archiveRoot) {
            var known = load(archiveRoot: archiveRoot)
            guard !known.contains(id) else { return }
            known.insert(id)
            try appendLine(id, archiveRoot: archiveRoot)
        }
    }

    /// Load log, merge favourite assetIds from sidecars (no hash verify), persist new lines, return full set.
    public static func loadMergingSidecars(archiveRoot: URL) throws -> Set<String> {
        try ArchiveLock.withLock(archiveRoot: archiveRoot) {
            var known = load(archiveRoot: archiveRoot)
            let fromSidecars = favouriteAssetIdsFromSidecars(archiveRoot: archiveRoot)
            let missing = fromSidecars.subtracting(known)
            for id in missing.sorted() {
                try appendLine(id, archiveRoot: archiveRoot)
                known.insert(id)
            }
            return known
        }
    }

    private static func appendLine(_ assetId: String, archiveRoot: URL) throws {
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let path = url(in: archiveRoot)
        let line = assetId + "\n"
        if !FileManager.default.fileExists(atPath: path.path) {
            try line.write(to: path, atomically: true, encoding: .utf8)
            return
        }
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    /// Sidecar `isFavorite == true` only — presence of sidecar implies a prior transfer attempt.
    private static func favouriteAssetIdsFromSidecars(archiveRoot: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: archiveRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var out = Set<String>()
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasSuffix(ArchieConstants.sidecarSuffix)
                || name.range(of: #"\.asset(-\d+)?\.json$"#, options: .regularExpression) != nil
            else { continue }
            guard let data = try? Data(contentsOf: url),
                  let doc = try? MessageCodec.decode(SidecarDocument.self, from: data),
                  doc.isFavorite,
                  !doc.assetId.isEmpty
            else { continue }
            out.insert(doc.assetId)
        }
        return out
    }
}
