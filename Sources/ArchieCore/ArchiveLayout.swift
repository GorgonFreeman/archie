import Foundation

public enum ArchiveLayout {
    /// Flat `<filename>` under the archive root, adding `-N` before the extension on collisions.
    public static func uniqueURL(
        archiveRoot: URL,
        originalFilename: String,
        creationDate: Date?
    ) -> (url: URL, relativePath: String) {
        _ = creationDate
        try? FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)

        let base = (originalFilename as NSString).deletingPathExtension
        let ext = (originalFilename as NSString).pathExtension
        var candidate = originalFilename
        var n = 0
        while FileManager.default.fileExists(atPath: archiveRoot.appendingPathComponent(candidate).path) {
            n += 1
            candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
        }
        return (archiveRoot.appendingPathComponent(candidate), candidate)
    }
}
