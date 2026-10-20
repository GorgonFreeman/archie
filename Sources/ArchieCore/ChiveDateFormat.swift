import Foundation

public enum ChiveDateFormat {
    /// `YYYY-MM-DD_HHhMMmSSs` or with `XXXms` when non-zero — matches chive/renamer.js.
    public static func format(_ date: Date) -> String {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let mo = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)
        let h = cal.component(.hour, from: date)
        let mi = cal.component(.minute, from: date)
        let s = cal.component(.second, from: date)
        let ms = cal.component(.nanosecond, from: date) / 1_000_000
        var time = String(format: "%02dh%02dm%02ds", h, mi, s)
        if ms != 0 {
            time += String(format: "%03dms", ms)
        }
        return String(format: "%04d-%02d-%02d_%@", y, mo, d, time)
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}_\d{2}h\d{2}m\d{2}s(\d{3}ms)?(_\d+)?$"#
    )

    public static func isFormattedBasename(_ basename: String) -> Bool {
        let range = NSRange(basename.startIndex..<basename.endIndex, in: basename)
        return pattern.firstMatch(in: basename, options: [], range: range) != nil
    }

    public static func uniqueURL(in directory: URL, baseName: String, ext: String) -> URL {
        let suffix = ext.isEmpty ? "" : (ext.hasPrefix(".") ? ext : ".\(ext)")
        var candidate = directory.appendingPathComponent("\(baseName)\(suffix)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)_\(n)\(suffix)")
            n += 1
        }
        return candidate
    }
}
