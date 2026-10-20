import Darwin
import Foundation

@MainActor
final class PinStore: ObservableObject {
    @Published private(set) var pin: String?
    @Published private(set) var receiverRunning = false

    private let pinFile: URL
    private let pidFile: URL
    private var timer: Timer?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Archie", isDirectory: true)
        pinFile = support.appendingPathComponent("current_pin.txt")
        pidFile = support.appendingPathComponent("receiver.pid")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let store = self else { return }
            DispatchQueue.main.async {
                store.refresh()
            }
        }
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
