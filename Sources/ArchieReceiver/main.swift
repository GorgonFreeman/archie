import ArchieCore
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: archie-receiver <archive-directory>\n", stderr)
    exit(1)
}

let archiveRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
TmpCleanup.clean(archiveRoot: archiveRoot)
// Also clear tmp under existing per-device folders.
if let kids = try? FileManager.default.contentsOfDirectory(
    at: archiveRoot,
    includingPropertiesForKeys: [.isDirectoryKey],
    options: [.skipsHiddenFiles]
) {
    for kid in kids {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: kid.path, isDirectory: &isDir), isDir.boolValue else {
            continue
        }
        TmpCleanup.clean(archiveRoot: kid)
    }
}

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("Archie", isDirectory: true)
try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
let identity = try TLSIdentity.loadOrCreate(in: support)
let pin = Pairing.makePin()

// For the USB watch LaunchAgent / UI — one-line PIN file.
let pinFile = support.appendingPathComponent("current_pin.txt")
try? pin.write(to: pinFile, atomically: true, encoding: .utf8)

fputs("Archie receiver\n", stderr)
fputs("archive base: \(archiveRoot.path)\n", stderr)
fputs("  (each phone writes to a subfolder named after the device)\n", stderr)
fputs("PIN: \(pin)\n", stderr)
fputs("waiting for iPhone on Bonjour \(ArchieConstants.bonjourType) …\n", stderr)

let server = ReceiverServer(
    archiveRoot: archiveRoot,
    pin: pin,
    identity: identity
)
try server.start()

RunLoop.main.run()
