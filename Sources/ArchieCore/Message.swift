import Foundation

public enum FrameType: UInt8, Sendable {
    case hello = 1
    case assetBegin = 2
    case chunk = 3
    case resourceEnd = 4
    case receipt = 5
    case fail = 6
    case sessionEnd = 7
    case assetSettle = 8
    case assetSettled = 9
}

public struct HelloPayload: Codable, Sendable {
    public var role: String
    public var pin: String?
    public var deviceName: String?

    public init(role: String, pin: String? = nil, deviceName: String? = nil) {
        self.role = role
        self.pin = pin
        self.deviceName = deviceName
    }
}

public struct AssetBeginPayload: Codable, Sendable {
    public var assetId: String
    public var resourceType: String
    public var originalFilename: String
    public var creationDate: Date?
    public var size: Int64
    public var declaredSha256: String
    public var isSidecar: Bool

    public init(
        assetId: String,
        resourceType: String,
        originalFilename: String,
        creationDate: Date?,
        size: Int64,
        declaredSha256: String,
        isSidecar: Bool = false
    ) {
        self.assetId = assetId
        self.resourceType = resourceType
        self.originalFilename = originalFilename
        self.creationDate = creationDate
        self.size = size
        self.declaredSha256 = declaredSha256
        self.isSidecar = isSidecar
    }
}

public struct ResourceEndPayload: Codable, Sendable {
    public var sha256: String
    public var size: Int64

    public init(sha256: String, size: Int64) {
        self.sha256 = sha256
        self.size = size
    }
}

public struct ReceiptPayload: Codable, Sendable {
    public var sha256: String
    public var size: Int64
    public var relativePath: String

    public init(sha256: String, size: Int64, relativePath: String) {
        self.sha256 = sha256
        self.size = size
        self.relativePath = relativePath
    }
}

public struct FailPayload: Codable, Sendable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public struct AssetSettlePayload: Codable, Sendable {
    public var assetId: String

    public init(assetId: String) {
        self.assetId = assetId
    }
}

public struct PathMapping: Codable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct AssetSettledPayload: Codable, Sendable {
    public var assetId: String
    public var paths: [PathMapping]

    public init(assetId: String, paths: [PathMapping]) {
        self.assetId = assetId
        self.paths = paths
    }
}

public enum MessageCodec {
    public static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try jsonEncoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try jsonDecoder.decode(type, from: data)
    }
}
