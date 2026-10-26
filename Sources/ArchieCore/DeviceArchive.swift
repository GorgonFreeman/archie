import Foundation

/// Per-phone folder under the archive base: `ArchieArchive/<device name>/`.
public enum DeviceArchive {
    /// Sanitize `UIDevice.current.name` (or similar) into a single path component.
    public static func folderName(forDeviceName raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "iPhone" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\:\0")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = base
            .components(separatedBy: invalid)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "-")
        if cleaned.isEmpty {
            return "iPhone"
        }
        // Keep Finder-friendly length.
        if cleaned.count > 120 {
            return String(cleaned.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }
        return cleaned
    }

    public static func root(baseArchiveRoot: URL, deviceName: String?) -> URL {
        baseArchiveRoot.appendingPathComponent(folderName(forDeviceName: deviceName), isDirectory: true)
    }
}
