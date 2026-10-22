import Foundation

/// Append-only log of protected asset IDs that verified as transferred (kept on phone).
/// Lives at `<archive>/.protected_seen_log` (one assetId per line).
/// Migrates legacy `.favourites_seen_log` on first access.
public enum ProtectedSeenLog {
    public static func url(in archiveRoot: URL) -> URL {
        archiveRoot.appendingPathComponent(ArchieConstants.protectedSeenLogName)
    }

    private static func legacyUrl(in archiveRoot: URL) -> URL {
        archiveRoot.appendingPathComponent(ArchieConstants.legacyFavouritesSeenLogName)
    }

    public static func load(archiveRoot: URL) -> Set<String> {
        migrateLegacyIfNeeded(archiveRoot: archiveRoot)
        let path = url(in: archiveRoot)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var out = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let id = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { out.insert(id) }
        }
        return out
    }

    /// Record a verified protected asset. Idempotent.
    public static func record(assetId: String, archiveRoot: URL) throws {
        let id = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        try ArchiveLock.withLock(archiveRoot: archiveRoot) {
            migrateLegacyIfNeeded(archiveRoot: archiveRoot)
            let known = loadUnlocked(archiveRoot: archiveRoot)
            guard !known.contains(id) else { return }
            try appendLine(id, archiveRoot: archiveRoot)
        }
    }

    /// Load log, merge favourite assetIds from sidecars (prior transfers), persist new lines, return full set.
    public static func loadMergingSidecars(archiveRoot: URL) throws -> Set<String> {
        try ArchiveLock.withLock(archiveRoot: archiveRoot) {
            migrateLegacyIfNeeded(archiveRoot: archiveRoot)
            var known = loadUnlocked(archiveRoot: archiveRoot)
            let fromSidecars = favouriteAssetIdsFromSidecars(archiveRoot: archiveRoot)
            let missing = fromSidecars.subtracting(known)
            for id in missing.sorted() {
                try appendLine(id, archiveRoot: archiveRoot)
                known.insert(id)
            }
            return known
        }
    }

    private static func loadUnlocked(archiveRoot: URL) -> Set<String> {
        let path = url(in: archiveRoot)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var out = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let id = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { out.insert(id) }
        }
        return out
    }

    private static func migrateLegacyIfNeeded(archiveRoot: URL) {
        let neu = url(in: archiveRoot)
        let old = legacyUrl(in: archiveRoot)
        guard !FileManager.default.fileExists(atPath: neu.path),
              FileManager.default.fileExists(atPath: old.path)
        else { return }
        try? FileManager.default.moveItem(at: old, to: neu)
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

    /// Sidecar `isFavorite == true` — those were kept on phone as protected favourites.
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
