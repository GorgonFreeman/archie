import Foundation

/// Assets imported under "protect last N days" — kept on phone until they age out.
/// Lives at `<archive>/.recent_seen_log` (JSONL: `RecentSeenEntry` per line).
public enum RecentSeenLog {
    public static func url(in archiveRoot: URL) -> URL {
        archiveRoot.appendingPathComponent(ArchieConstants.recentSeenLogName)
    }

    public static func load(archiveRoot: URL) -> [RecentSeenEntry] {
        let path = url(in: archiveRoot)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var byId: [String: RecentSeenEntry] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let entry = try? MessageCodec.decode(RecentSeenEntry.self, from: data),
                  !entry.assetId.isEmpty
            else { continue }
            byId[entry.assetId] = entry
        }
        return byId.values.sorted { $0.assetId < $1.assetId }
    }

    public static func loadIds(archiveRoot: URL) -> Set<String> {
        Set(load(archiveRoot: archiveRoot).map(\.assetId))
    }

    /// Record a verified recent-window asset. Idempotent (updates creationDate if provided).
    public static func record(assetId: String, creationDate: Date?, archiveRoot: URL) throws {
        let id = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        try ArchiveLock.withLock(archiveRoot: archiveRoot) {
            var byId = Dictionary(
                uniqueKeysWithValues: loadUnlocked(archiveRoot: archiveRoot).map { ($0.assetId, $0) }
            )
            byId[id] = RecentSeenEntry(assetId: id, creationDate: creationDate ?? byId[id]?.creationDate)
            try rewrite(Array(byId.values), archiveRoot: archiveRoot)
        }
    }

    /// Drop after a successful phone delete (or if gone from the library).
    public static func remove(assetId: String, archiveRoot: URL) throws {
        let id = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        try ArchiveLock.withLock(archiveRoot: archiveRoot) {
            var entries = loadUnlocked(archiveRoot: archiveRoot)
            let before = entries.count
            entries.removeAll { $0.assetId == id }
            guard entries.count != before else { return }
            try rewrite(entries, archiveRoot: archiveRoot)
        }
    }

    public static func cutoff(now: Date = Date()) -> Date {
        Calendar.current.date(
            byAdding: .day,
            value: -ArchieConstants.recentProtectDayCount,
            to: now
        ) ?? now.addingTimeInterval(
            TimeInterval(-ArchieConstants.recentProtectDayCount * 24 * 60 * 60)
        )
    }

    public static func isWithinWindow(creationDate: Date?, now: Date = Date()) -> Bool {
        guard let creationDate else { return false }
        return creationDate >= cutoff(now: now)
    }

    public static func isAgedOut(creationDate: Date?, now: Date = Date()) -> Bool {
        guard let creationDate else { return true }
        return creationDate < cutoff(now: now)
    }

    private static func loadUnlocked(archiveRoot: URL) -> [RecentSeenEntry] {
        let path = url(in: archiveRoot)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var byId: [String: RecentSeenEntry] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let entry = try? MessageCodec.decode(RecentSeenEntry.self, from: data),
                  !entry.assetId.isEmpty
            else { continue }
            byId[entry.assetId] = entry
        }
        return Array(byId.values)
    }

    private static func rewrite(_ entries: [RecentSeenEntry], archiveRoot: URL) throws {
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let path = url(in: archiveRoot)
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
            return
        }
        var lines: [String] = []
        for entry in entries.sorted(by: { $0.assetId < $1.assetId }) {
            let data = try MessageCodec.encode(entry)
            guard let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
    }
}
