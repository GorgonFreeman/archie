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

    /// Rewrite relative paths for an asset after settle-rename; refresh sidecar hash/size.
    public func remapAsset(
        assetId: String,
        pathMap: [String: String],
        sidecarRelativePath: String,
        sidecarSha256: String,
        sidecarSize: Int64
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        out.reserveCapacity(lines.count)

        for line in lines {
            if line.isEmpty {
                out.append("")
                continue
            }
            guard var row = try? MessageCodec.decode(ManifestRecord.self, from: Data(line.utf8)) else {
                out.append(String(line))
                continue
            }
            guard row.assetId == assetId else {
                out.append(String(line))
                continue
            }
            if let mapped = pathMap[row.relativePath] {
                row.relativePath = mapped
            }
            if row.resourceType == "sidecar" || row.relativePath.hasSuffix(ArchieConstants.sidecarSuffix) {
                row.relativePath = sidecarRelativePath
                row.sha256 = sidecarSha256
                row.size = sidecarSize
            }
            let encoded = try MessageCodec.encode(row)
            out.append(String(decoding: encoded, as: UTF8.self))
        }

        let joined = out.joined(separator: "\n")
        let final = joined.hasSuffix("\n") || joined.isEmpty ? joined : joined + "\n"
        try final.write(to: url, atomically: true, encoding: .utf8)
    }
}
