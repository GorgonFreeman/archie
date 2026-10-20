import Darwin
import Foundation

final class PinStore {
    private(set) var pin: String?
    private(set) var receiverRunning = false

    private let pinFile: URL
    private let pidFile: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Archie", isDirectory: true)
        pinFile = support.appendingPathComponent("current_pin.txt")
        pidFile = support.appendingPathComponent("receiver.pid")
        refresh()
    }

    func refresh() {
        if let text = try? String(contentsOf: pinFile, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            pin = trimmed.isEmpty ? nil : trimmed
        } else {
            pin = nil
        }

        if let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0 {
            receiverRunning = kill(pid, 0) == 0
        } else {
            receiverRunning = false
        }
    }
}
