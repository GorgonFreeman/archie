import Foundation

public struct ManifestRecord: Codable, Sendable {
    public var assetId: String
    public var resourceType: String
    public var relativePath: String
    public var size: Int64
    public var sha256: String
    public var timestamp: Date

    public init(
        assetId: String,
        resourceType: String,
        relativePath: String,
        size: Int64,
        sha256: String,
        timestamp: Date = Date()
    ) {
        self.assetId = assetId
        self.resourceType = resourceType
        self.relativePath = relativePath
        self.size = size
        self.sha256 = sha256
        self.timestamp = timestamp
    }
}

public final class ManifestStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(archiveRoot: URL) throws {
        url = archiveRoot.appendingPathComponent(ArchieConstants.manifestName)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    public func append(_ record: ManifestRecord) throws {
        var data = try MessageCodec.encode(record)
        data.append(contentsOf: [0x0A])
        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
