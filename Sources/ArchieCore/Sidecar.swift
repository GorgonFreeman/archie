import Foundation

public struct SidecarLocation: Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public struct SidecarAlbum: Codable, Sendable {
    public var name: String
    public var localIdentifier: String

    public init(name: String, localIdentifier: String) {
        self.name = name
        self.localIdentifier = localIdentifier
    }
}

public struct SidecarResource: Codable, Sendable {
    public var type: String
    public var originalFilename: String
    public var size: Int64
    public var sha256: String
    public var relativePath: String

    public init(
        type: String,
        originalFilename: String,
        size: Int64,
        sha256: String,
        relativePath: String
    ) {
        self.type = type
        self.originalFilename = originalFilename
        self.size = size
        self.sha256 = sha256
        self.relativePath = relativePath
    }
}

public struct SidecarDocument: Codable, Sendable {
    public var assetId: String
    public var importedAt: Date
    public var deviceModel: String
    public var iosVersion: String
    public var creationDate: Date?
    public var modificationDate: Date?
    public var location: SidecarLocation?
    public var isFavorite: Bool
    public var isHidden: Bool
    public var albums: [SidecarAlbum]
    public var mediaType: String
    public var subtypes: [String]
    public var burstIdentifier: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: Double
    public var resources: [SidecarResource]

    public init(
        assetId: String,
        importedAt: Date = Date(),
        deviceModel: String,
        iosVersion: String,
        creationDate: Date?,
        modificationDate: Date?,
        location: SidecarLocation?,
        isFavorite: Bool,
        isHidden: Bool,
        albums: [SidecarAlbum],
        mediaType: String,
        subtypes: [String],
        burstIdentifier: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: Double,
        resources: [SidecarResource]
    ) {
        self.assetId = assetId
        self.importedAt = importedAt
        self.deviceModel = deviceModel
        self.iosVersion = iosVersion
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.location = location
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.albums = albums
        self.mediaType = mediaType
        self.subtypes = subtypes
        self.burstIdentifier = burstIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.resources = resources
    }
}
