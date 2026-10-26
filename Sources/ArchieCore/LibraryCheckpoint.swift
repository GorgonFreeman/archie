import Foundation

/// Phone library snapshot written by the Mac receiver for before/after delete audits.
public struct LibraryCheckpoint: Codable, Sendable {
    public var version: Int
    public var createdAt: Date
    public var label: String
    public var deviceName: String
    public var assetCount: Int
    public var assetIds: [String]

    public init(
        version: Int = 1,
        createdAt: Date = Date(),
        label: String,
        deviceName: String,
        assetIds: [String]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.label = label
        self.deviceName = deviceName
        self.assetCount = assetIds.count
        self.assetIds = assetIds
    }
}

public enum LibraryCheckpointStore {
    public static func checkpointsDirectory() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Archie", isDirectory: true)
            .appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    /// Writes `checkpoint-<label>-<timestamp>.json`, updates `latest.json`, and `baseline.json` when labeled baseline.
    @discardableResult
    public static func save(_ checkpoint: LibraryCheckpoint) throws -> URL {
        let dir = try checkpointsDirectory()
        let stamp = isoStamp(checkpoint.createdAt)
        let safeLabel = checkpoint.label
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let file = dir.appendingPathComponent("checkpoint-\(safeLabel)-\(stamp).json")
        let data = try MessageCodec.encode(checkpoint)
        try data.write(to: file, options: .atomic)

        let latest = dir.appendingPathComponent("latest.json")
        try data.write(to: latest, options: .atomic)

        if checkpoint.label == "baseline" {
            let baseline = dir.appendingPathComponent("baseline.json")
            try data.write(to: baseline, options: .atomic)
        }

        // Tiny summary for agents / scripts (no full ID list).
        let summary: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: checkpoint.createdAt),
            "label": checkpoint.label,
            "deviceName": checkpoint.deviceName,
            "assetCount": checkpoint.assetCount,
            "path": file.path,
            "latestPath": latest.path,
        ]
        let summaryData = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try summaryData.write(
            to: dir.appendingPathComponent("latest_summary.json"),
            options: .atomic
        )

        return file
    }

    public static func load(from url: URL) throws -> LibraryCheckpoint {
        let data = try Data(contentsOf: url)
        return try MessageCodec.decode(LibraryCheckpoint.self, from: data)
    }

    public static func compare(before: LibraryCheckpoint, after: LibraryCheckpoint) -> CheckpointDiff {
        let beforeSet = Set(before.assetIds)
        let afterSet = Set(after.assetIds)
        let removed = beforeSet.subtracting(afterSet)
        let added = afterSet.subtracting(beforeSet)
        return CheckpointDiff(
            beforeCount: before.assetCount,
            afterCount: after.assetCount,
            removedCount: removed.count,
            addedCount: added.count,
            removedIds: removed.sorted(),
            addedIds: added.sorted()
        )
    }

    private static func isoStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}

public struct CheckpointDiff: Sendable {
    public var beforeCount: Int
    public var afterCount: Int
    public var removedCount: Int
    public var addedCount: Int
    public var removedIds: [String]
    public var addedIds: [String]

    public var netChange: Int { afterCount - beforeCount }
}
