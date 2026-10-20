import Foundation

public enum ArchiveLayout {
    /// `YYYY/MM/<filename>`, adding `-N` before the extension on collisions.
    public static func uniqueURL(
        archiveRoot: URL,
        originalFilename: String,
        creationDate: Date?
    ) -> (url: URL, relativePath: String) {
        let date = creationDate ?? Date()
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let dirRel = String(format: "%04d/%02d", y, m)
        let dir = archiveRoot.appendingPathComponent(dirRel, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let base = (originalFilename as NSString).deletingPathExtension
        let ext = (originalFilename as NSString).pathExtension
        var candidate = originalFilename
        var n = 0
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            n += 1
            candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
        }
        let rel = "\(dirRel)/\(candidate)"
        return (dir.appendingPathComponent(candidate), rel)
    }
}
