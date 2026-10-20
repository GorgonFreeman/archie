import Foundation

public enum ArchieConstants {
    public static let bonjourType = "_archie._tcp"
    public static let bonjourDomain = "local."
    public static let chunkSize = 2 * 1024 * 1024
    public static let maxAttempts = 3
    public static let tmpDirName = ".archie-tmp"
    public static let manifestName = "manifest.jsonl"
}
