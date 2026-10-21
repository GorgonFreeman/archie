import Foundation

public struct SettledResource: Sendable {
    public var relativePath: String
    public var sha256: String
    public var isSidecar: Bool

    public init(relativePath: String, sha256: String, isSidecar: Bool) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.isSidecar = isSidecar
    }
}

public enum AssetRenamerError: Error, LocalizedError {
    case missingFile(String)
    case hashMismatch(String)
    case noMedia
    case sidecarDecode
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let p): return "missing file \(p)"
        case .hashMismatch(let p): return "hash mismatch \(p)"
        case .noMedia: return "no media resources to rename"
        case .sidecarDecode: return "could not decode sidecar"
        case .rollbackFailed(let m): return "rollback failed: \(m)"
        }
    }
}

/// Per-asset date rename after verify; updates sidecar paths + manifest. Never re-encodes.
public enum AssetRenamer {
    /// - Returns: map of old relative path → new relative path (identity entries omitted).
    public static func settle(
        archiveRoot: URL,
        assetId: String,
        creationDate: Date?,
        resources: [SettledResource],
        manifest: ManifestStore
    ) throws -> [String: String] {
        try ArchiveLock.withLock(archiveRoot: archiveRoot) {
            try settleLocked(
                archiveRoot: archiveRoot,
                assetId: assetId,
                creationDate: creationDate,
                resources: resources,
                manifest: manifest
            )
        }
    }

    private static func settleLocked(
        archiveRoot: URL,
        assetId: String,
        creationDate: Date?,
        resources: [SettledResource],
        manifest: ManifestStore
    ) throws -> [String: String] {
        let media = resources.filter { !$0.isSidecar }
        let sidecars = resources.filter(\.isSidecar)
        guard !media.isEmpty else { throw AssetRenamerError.noMedia }
        guard sidecars.count == 1 else { throw AssetRenamerError.missingFile("sidecar") }

        // Verify bytes still match declared hashes.
        for r in resources {
            let url = archiveRoot.appendingPathComponent(r.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AssetRenamerError.missingFile(r.relativePath)
            }
            let dig = try Sha256Hasher.hash(fileAt: url)
            guard dig == r.sha256.lowercased() else {
                throw AssetRenamerError.hashMismatch(r.relativePath)
            }
        }

        let date = creationDate ?? Date()
        let base = ChiveDateFormat.format(date)

        // Idempotent: if every media basename is already formatted and sidecar is `<primary>.asset.json`, done.
        if isAlreadySettled(media: media, sidecar: sidecars[0]) {
            return [:]
        }

        var plan: [(from: URL, to: URL, oldRel: String, newRel: String)] = []
        var pathMap: [String: String] = [:]
        var reserved = Set<String>()

        for r in media {
            let from = archiveRoot.appendingPathComponent(r.relativePath)
            let ext = (r.relativePath as NSString).pathExtension
            let to = allocateUnique(
                directory: archiveRoot,
                baseName: base,
                ext: ext,
                from: from,
                reserved: &reserved
            )
            let newRel = to.lastPathComponent
            pathMap[r.relativePath] = newRel
            if from.standardizedFileURL != to.standardizedFileURL {
                plan.append((from, to, r.relativePath, newRel))
            }
        }

        let primaryOld = media[0].relativePath
        let primaryNew = pathMap[primaryOld] ?? primaryOld
        let sidecarOld = sidecars[0].relativePath
        let sidecarNew = primaryNew + ArchieConstants.sidecarSuffix
        let sidecarFrom = archiveRoot.appendingPathComponent(sidecarOld)
        let sidecarTo = archiveRoot.appendingPathComponent(sidecarNew)
        pathMap[sidecarOld] = sidecarNew

        let originalSidecarData = try Data(contentsOf: sidecarFrom)
        var movedMedia: [(current: URL, original: URL)] = []
        do {
            for step in plan {
                try FileManager.default.moveItem(at: step.from, to: step.to)
                movedMedia.append((step.to, step.from))
            }

            // Rewrite sidecar JSON with new relative paths, write to new name.
            var doc = try MessageCodec.decode(SidecarDocument.self, from: originalSidecarData)
            doc.resources = doc.resources.map { r in
                var next = r
                next.relativePath = pathMap[r.relativePath] ?? r.relativePath
                return next
            }
            let newData = try MessageCodec.encode(doc)
            if sidecarFrom.standardizedFileURL != sidecarTo.standardizedFileURL {
                try newData.write(to: sidecarTo, options: .atomic)
                try FileManager.default.removeItem(at: sidecarFrom)
            } else {
                try newData.write(to: sidecarTo, options: .atomic)
            }

            let newSidecarHash = Sha256Hasher()
            newSidecarHash.update(newData)
            let sidecarDigest = newSidecarHash.finalize()

            try manifest.remapAsset(
                assetId: assetId,
                pathMap: pathMap,
                sidecarRelativePath: sidecarNew,
                sidecarSha256: sidecarDigest,
                sidecarSize: Int64(newData.count)
            )
        } catch {
            // Restore media names, then original sidecar bytes/path.
            for step in movedMedia.reversed() {
                if FileManager.default.fileExists(atPath: step.current.path),
                   !FileManager.default.fileExists(atPath: step.original.path) {
                    try? FileManager.default.moveItem(at: step.current, to: step.original)
                }
            }
            if sidecarFrom.standardizedFileURL != sidecarTo.standardizedFileURL,
               FileManager.default.fileExists(atPath: sidecarTo.path) {
                try? FileManager.default.removeItem(at: sidecarTo)
            }
            try? originalSidecarData.write(to: sidecarFrom, options: .atomic)
            throw error
        }

        return pathMap.filter { $0.key != $0.value }
    }

    private static func isAlreadySettled(media: [SettledResource], sidecar: SettledResource) -> Bool {
        for r in media {
            let base = ((r.relativePath as NSString).deletingPathExtension as String)
            if !ChiveDateFormat.isFormattedBasename(base) { return false }
        }
        let primary = media[0].relativePath
        let expectedSide = primary + ArchieConstants.sidecarSuffix
        return sidecar.relativePath == expectedSide
    }

    private static func allocateUnique(
        directory: URL,
        baseName: String,
        ext: String,
        from: URL,
        reserved: inout Set<String>
    ) -> URL {
        // Lowercase extensions so .MOV / .mov claim the same name on case-insensitive APFS.
        let raw = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        let suffix = raw.isEmpty ? "" : ".\(raw.lowercased())"
        var n = 0
        while true {
            let name = n == 0 ? "\(baseName)\(suffix)" : "\(baseName)_\(n)\(suffix)"
            let key = name.lowercased()
            let url = directory.appendingPathComponent(name)
            let takenOnDisk = FileManager.default.fileExists(atPath: url.path)
                && url.standardizedFileURL != from.standardizedFileURL
            if !takenOnDisk && !reserved.contains(key) {
                reserved.insert(key)
                return url
            }
            n += 1
        }
    }
}
