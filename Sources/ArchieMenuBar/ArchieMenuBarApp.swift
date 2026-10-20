import AppKit
import SwiftUI

@main
struct ArchieMenuBarApp: App {
    @StateObject private var store = PinStore()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 10) {
                Text("Archie")
                    .font(.headline)

                if let pin = store.pin, store.receiverRunning {
                    Text("PIN")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pin)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)

                    Button("Copy PIN") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pin, forType: .string)
                    }
                    .keyboardShortcut("c", modifiers: .command)
                } else if store.receiverRunning {
                    Text("Receiver running — waiting for PIN…")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Receiver stopped")
                        .foregroundStyle(.secondary)
                    Text("Plug in an iPhone to start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button("Quit Archie Menu") {
                    NSApp.terminate(nil)
                }
            }
            .padding(12)
            .frame(width: 220)
        } label: {
            if let pin = store.pin, store.receiverRunning {
                Text("Archie \(pin)")
            } else {
                Label("Archie", systemImage: "iphone")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
