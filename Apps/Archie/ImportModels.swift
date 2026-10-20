import Foundation

enum RetainReason: String, Sendable {
    case protected
    case failed
    case unreadable
    case sidecarFailed
    case limitedAccess
}

struct AssetOutcome: Identifiable, Sendable {
    var id: String
    var bytes: Int64
    var verified: Bool
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

    var eligibleForDelete: [AssetOutcome] {
        outcomes.filter { $0.verified && $0.retainReason == nil }
    }

    var retainedOutcomes: [AssetOutcome] {
        outcomes.filter { $0.retainReason != nil }
    }
}
