import ArchieCore
import Foundation

/// Backlog: date-rename assets whose media still has raw names (IMG_, FullSizeRender, …).
/// Usage: archie-settle-leftovers <archive-dir>
@main
enum SettleLeftoversMain {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 2 else {
            fputs("usage: archie-settle-leftovers <archive-dir>\n", stderr)
            exit(1)
        }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            fputs("not a directory: \(root.path)\n", stderr)
            exit(1)
        }

        let manifest = try ManifestStore(archiveRoot: root)
        // Include collision spellings like `IMG_….HEIC.asset-1.json` from ArchiveLayout.
        let sidecars = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { nameIsSidecar($0.lastPathComponent) }

        var settled = 0
        var skipped = 0
        var failed = 0

        for sideURL in sidecars.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let sideName = sideURL.lastPathComponent
            let raw: Data
            do {
                raw = try Data(contentsOf: sideURL)
            } catch {
                fputs("skip unreadable \(sideName): \(error.localizedDescription)\n", stderr)
                failed += 1
                continue
            }
            let doc: SidecarDocument
            do {
                doc = try MessageCodec.decode(SidecarDocument.self, from: raw)
            } catch {
                fputs("skip bad json \(sideName): \(error.localizedDescription)\n", stderr)
                failed += 1
                continue
            }

            let mediaPaths = doc.resources.map(\.relativePath)
            let needsRename = mediaPaths.contains { path in
                let base = (path as NSString).deletingPathExtension
                return !ChiveDateFormat.isFormattedBasename(base)
            }
            if !needsRename {
                skipped += 1
                continue
            }

            var resources: [SettledResource] = []
            var ok = true
            for r in doc.resources {
                let url = root.appendingPathComponent(r.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    fputs("missing \(r.relativePath) for \(doc.assetId)\n", stderr)
                    ok = false
                    break
                }
                let dig: String
                do {
                    dig = try Sha256Hasher.hash(fileAt: url)
                } catch {
                    fputs("hash fail \(r.relativePath): \(error.localizedDescription)\n", stderr)
                    ok = false
                    break
                }
                resources.append(SettledResource(
                    relativePath: r.relativePath,
                    sha256: dig,
                    isSidecar: false
                ))
            }
            guard ok else {
                failed += 1
                continue
            }

            let sideDig = try Sha256Hasher.hash(fileAt: sideURL)
            resources.append(SettledResource(
                relativePath: sideName,
                sha256: sideDig,
                isSidecar: true
            ))

            do {
                let map = try AssetRenamer.settle(
                    archiveRoot: root,
                    assetId: doc.assetId,
                    creationDate: doc.creationDate,
                    resources: resources,
                    manifest: manifest
                )
                if map.isEmpty {
                    skipped += 1
                } else {
                    settled += 1
                    fputs("settled \(doc.assetId) (\(map.count) renames)\n", stderr)
                }
            } catch {
                failed += 1
                fputs("fail \(doc.assetId): \(error.localizedDescription)\n", stderr)
            }
        }

        print("done settled=\(settled) skipped=\(skipped) failed=\(failed)")
        if failed > 0 { exit(2) }
    }

    private static func nameIsSidecar(_ name: String) -> Bool {
        if name.hasSuffix(ArchieConstants.sidecarSuffix) { return true }
        // e.g. foo.HEIC.asset-1.json
        return name.range(of: #"\.asset(-\d+)?\.json$"#, options: .regularExpression) != nil
    }
}
