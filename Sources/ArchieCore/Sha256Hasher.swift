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
        while true {
            let chunk = handle.readData(ofLength: ArchieConstants.chunkSize)
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.finalize()
    }
}
