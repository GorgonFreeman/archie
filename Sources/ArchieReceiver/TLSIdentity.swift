import Foundation
import Security

enum TLSIdentity {
    static func loadOrCreate(in directory: URL) throws -> SecIdentity {
        let p12URL = directory.appendingPathComponent("archie-tls.p12")
        let password = "archie"
        if FileManager.default.fileExists(atPath: p12URL.path),
           let identity = try? loadP12(at: p12URL, password: password) {
            return identity
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try generateP12(at: p12URL, password: password)
        return try loadP12(at: p12URL, password: password)
    }

    private static func generateP12(at p12URL: URL, password: String) throws {
        let dir = p12URL.deletingLastPathComponent()
        let keyURL = dir.appendingPathComponent("archie-key.pem")
        let certURL = dir.appendingPathComponent("archie-cert.pem")
        try run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", "825", "-nodes",
            "-subj", "/CN=Archie Receiver",
        ])
        try run("/usr/bin/openssl", [
            "pkcs12", "-export",
            "-out", p12URL.path,
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-passout", "pass:\(password)",
        ])
        try? FileManager.default.removeItem(at: keyURL)
        try? FileManager.default.removeItem(at: certURL)
    }

    private static func loadP12(at url: URL, password: String) throws -> SecIdentity {
        let data = try Data(contentsOf: url)
        let opts: NSDictionary = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, opts, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw ReceiverError.tlsIdentity
        }
        return identity as! SecIdentity
    }

    private static func run(_ launchPath: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ReceiverError.openssl(msg)
        }
    }
}

enum ReceiverError: Error, LocalizedError {
    case tlsIdentity
    case openssl(String)
    case usage
    case badPin
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .tlsIdentity: return "could not load TLS identity"
        case .openssl(let m): return "openssl failed: \(m)"
        case .usage: return "usage: archie-receiver <archive-directory>"
        case .badPin: return "PIN mismatch"
        case .protocolError(let m): return m
        }
    }
}
