import CryptoKit
import Foundation

public final class Sha256Hasher: @unchecked Sendable {
    private var hasher = SHA256()

    public init() {}

    public func update(_ data: Data) {
        hasher.update(data: data)
    }

    public func update(_ bytes: UnsafeRawBufferPointer) {
        hasher.update(bufferPointer: bytes)
    }

    public func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let hasher = Sha256Hasher()
        // Smaller chunks + autoreleasepool keep peak memory flat on huge archive scans.
        let chunkLen = min(ArchieConstants.chunkSize, 256 * 1024)
        while true {
            let chunk: Data = try autoreleasepool {
                if let data = try handle.read(upToCount: chunkLen) {
                    return data
                }
                return Data()
            }
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.finalize()
    }
}
