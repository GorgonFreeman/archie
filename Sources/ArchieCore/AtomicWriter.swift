import Darwin
import Foundation

public struct WriteResult: Sendable {
    public let relativePath: String
    public let sha256: String
    public let size: Int64
}

public enum AtomicWriterError: Error, LocalizedError {
    case hashMismatch(expected: String, during: String, final: String)
    case incomplete(expected: Int64, got: Int64)
    case fsyncFailed

    public var errorDescription: String? {
        switch self {
        case .hashMismatch(let e, let d, let f):
            return "hash mismatch declared=\(e) during=\(d) final=\(f)"
        case .incomplete(let e, let g):
            return "incomplete write expected=\(e) got=\(g)"
        case .fsyncFailed:
            return "F_FULLFSYNC failed"
        }
    }
}

/// Streams bytes to a temp file (hashing as it goes), fsyncs, renames, re-hashes.
public final class AtomicWriter: @unchecked Sendable {
    private let archiveRoot: URL
    private let tmpURL: URL
    private let finalURL: URL
    private let relativePath: String
    private let expectedSize: Int64
    private let declaredSha256: String
    private let handle: FileHandle
    private let duringHasher = Sha256Hasher()
    private var written: Int64 = 0

    public init(
        archiveRoot: URL,
        originalFilename: String,
        creationDate: Date?,
        expectedSize: Int64,
        declaredSha256: String
    ) throws {
        self.archiveRoot = archiveRoot
        self.expectedSize = expectedSize
        self.declaredSha256 = declaredSha256.lowercased()

        let tmpRoot = archiveRoot.appendingPathComponent(ArchieConstants.tmpDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

        let dest = ArchiveLayout.uniqueURL(
            archiveRoot: archiveRoot,
            originalFilename: originalFilename,
            creationDate: creationDate
        )
        self.finalURL = dest.url
        self.relativePath = dest.relativePath
        self.tmpURL = tmpRoot.appendingPathComponent(UUID().uuidString)

        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: tmpURL)
    }

    public func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        duringHasher.update(data)
        written += Int64(data.count)
    }

    public func finish() throws -> WriteResult {
        try handle.synchronize()
        try fullFsync(handle)
        try handle.close()

        guard written == expectedSize else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw AtomicWriterError.incomplete(expected: expectedSize, got: written)
        }

        let duringHash = duringHasher.finalize()
        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
        let finalHash = try Sha256Hasher.hash(fileAt: finalURL)

        guard duringHash == declaredSha256, finalHash == declaredSha256 else {
            try? FileManager.default.removeItem(at: finalURL)
            throw AtomicWriterError.hashMismatch(
                expected: declaredSha256,
                during: duringHash,
                final: finalHash
            )
        }

        return WriteResult(relativePath: relativePath, sha256: finalHash, size: written)
    }

    public func abort() {
        try? handle.close()
        try? FileManager.default.removeItem(at: tmpURL)
        try? FileManager.default.removeItem(at: finalURL)
    }

    private func fullFsync(_ handle: FileHandle) throws {
        let ok = fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0
        if !ok { throw AtomicWriterError.fsyncFailed }
    }
}

public enum TmpCleanup {
    public static func clean(archiveRoot: URL) {
        let tmp = archiveRoot.appendingPathComponent(ArchieConstants.tmpDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
}
