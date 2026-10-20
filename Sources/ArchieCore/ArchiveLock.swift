import Darwin
import Foundation

public enum ArchiveLockError: Error, LocalizedError {
    case busy(pid: Int32)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .busy(let pid): return "archive locked by pid \(pid)"
        case .io(let m): return m
        }
    }
}

/// Exclusive archive lock shared by live settle and backlog rename.
public enum ArchiveLock {
    public static func withLock<T>(archiveRoot: URL, _ body: () throws -> T) throws -> T {
        let url = archiveRoot.appendingPathComponent(ArchieConstants.archiveLockName)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: url.path) {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0,
               kill(pid, 0) == 0 {
                throw ArchiveLockError.busy(pid: pid)
            }
            try? FileManager.default.removeItem(at: url)
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        do {
            try String(pid).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ArchiveLockError.io("could not write lock: \(error.localizedDescription)")
        }

        defer { try? FileManager.default.removeItem(at: url) }
        return try body()
    }
}
