import Foundation

public enum ArchieConstants {
    public static let bonjourType = "_archie._tcp"
    public static let bonjourDomain = "local."
    public static let chunkSize = 2 * 1024 * 1024
    public static let maxAttempts = 3
    public static let tmpDirName = ".archie-tmp"
    public static let manifestName = "manifest.jsonl"
    public static let archiveLockName = ".archie-archive.lock"
    public static let protectedSeenLogName = ".protected_seen_log"
    /// Migrated once into `protectedSeenLogName`.
    public static let legacyFavouritesSeenLogName = ".favourites_seen_log"
    public static let sidecarSuffix = ".asset.json"
    /// Max wait for a normal reply (hello, settle, ping, receipt after send).
    public static let ioTimeoutNanoseconds: UInt64 = 120_000_000_000
    /// Short probe used before resume.
    public static let pingTimeoutNanoseconds: UInt64 = 5_000_000_000
}
