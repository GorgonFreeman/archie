import Foundation

public struct ArchiveIndexReport: Sendable {
    /// Sidecars whose every listed resource exists and matches sha256.
    public var completeAssetIds: [String]
    /// Sidecars that failed existence/hash checks (logged; not safe to delete from phone).
    public var incompleteCount: Int
}

/// Asset IDs present in the archive, derived from sidecars — only after byte verification.
public enum ArchiveIndex {
    public static func verifiedAssetIds(in archiveRoot: URL) -> ArchiveIndexReport {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: nil
        ) else {
            return ArchiveIndexReport(completeAssetIds: [], incompleteCount: 0)
        }

        var complete = Set<String>()
        var incomplete = 0

        for url in files {
            let name = url.lastPathComponent
            guard nameContainsSidecar(name) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let doc = try? MessageCodec.decode(SidecarDocument.self, from: data),
                  !doc.assetId.isEmpty else {
                incomplete += 1
                continue
            }

            if isComplete(doc: doc, archiveRoot: archiveRoot) {
                complete.insert(doc.assetId)
            } else {
                incomplete += 1
            }
        }

        return ArchiveIndexReport(
            completeAssetIds: complete.sorted(),
            incompleteCount: incomplete
        )
    }

    /// Every resource in the sidecar must exist on disk with a matching SHA-256.
    public static func isComplete(doc: SidecarDocument, archiveRoot: URL) -> Bool {
        let resources = doc.resources
        guard !resources.isEmpty else { return false }

        for r in resources {
            let rel = r.relativePath
            guard !rel.isEmpty, !r.sha256.isEmpty else { return false }
            let file = archiveRoot.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: file.path) else { return false }
            guard let dig = try? Sha256Hasher.hash(fileAt: file) else { return false }
            guard dig == r.sha256.lowercased() else { return false }
            // Size is advisory — prefer hash as source of truth; still reject obvious truncation.
            if r.size > 0 {
                let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                if let n = attrs?[.size] as? NSNumber, n.int64Value != r.size {
                    return false
                }
            }
        }
        return true
    }

    private static func nameContainsSidecar(_ name: String) -> Bool {
        if name.hasSuffix(ArchieConstants.sidecarSuffix) { return true }
        return name.range(of: #"\.asset(-\d+)?\.json$"#, options: .regularExpression) != nil
    }
}
