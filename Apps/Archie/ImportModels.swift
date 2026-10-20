import Foundation

enum RetainReason: String, Sendable {
    case protected
    case failed
    case unreadable
    case sidecarFailed
    case limitedAccess
    case deleteDeclined
    case settleFailed
}

struct AssetOutcome: Identifiable, Sendable {
    var id: String
    var bytes: Int64
    var verified: Bool
    var deleted: Bool
    var retainReason: RetainReason?
}

struct ImportSummary: Sendable {
    var imported: Int = 0
    var verified: Int = 0
    var failed: Int = 0
    var retained: Int = 0
    var deleted: Int = 0
    var bytesVerified: Int64 = 0
    var outcomes: [AssetOutcome] = []

    var retainedOutcomes: [AssetOutcome] {
        outcomes.filter { $0.retainReason != nil }
    }
}

/// One Mac-side receipt that the phone has checked against its declared hash/size.
struct MatchedReceipt: Sendable {
    var type: String
    var originalFilename: String
    var size: Int64
    var sha256: String
    var relativePath: String
}

/// Proof that every media resource *and* the sidecar got a matching RECEIPT this run.
/// Only `make` can construct it — deletion must take this type, not a bool.
struct VerifiedCopy: Sendable {
    let assetId: String
    let bytes: Int64
    let receipts: [MatchedReceipt]

    private init(assetId: String, bytes: Int64, receipts: [MatchedReceipt]) {
        self.assetId = assetId
        self.bytes = bytes
        self.receipts = receipts
    }

    /// - Parameters:
    ///   - expectedMediaCount: number of PhotoKit resources that must each have a receipt
    ///   - receipts: media receipts + exactly one `sidecar` receipt
    static func make(
        assetId: String,
        expectedMediaCount: Int,
        receipts: [MatchedReceipt]
    ) -> VerifiedCopy? {
        guard expectedMediaCount > 0 else { return nil }
        let media = receipts.filter { $0.type != "sidecar" }
        let sidecars = receipts.filter { $0.type == "sidecar" }
        guard media.count == expectedMediaCount, sidecars.count == 1 else { return nil }
        guard media.allSatisfy(Self.isComplete), isComplete(sidecars[0]) else { return nil }
        let bytes = media.reduce(Int64(0)) { $0 + $1.size }
        return VerifiedCopy(assetId: assetId, bytes: bytes, receipts: media + sidecars)
    }

    private static func isComplete(_ r: MatchedReceipt) -> Bool {
        !r.relativePath.isEmpty && r.size >= 0 && r.sha256.count == 64
    }
}
