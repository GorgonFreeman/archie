import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var store: PinStore?
    private var refreshTimer: Timer?
    /// Avoid replacing `statusItem.menu` every tick — that closes the menu / eats clicks.
    private var lastMenuSignature = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = PinStore()
        self.store = store

        UserDefaults.standard.set(Double(12_000), forKey: "NSStatusItem Preferred Position archie.pin")
        installStatusItem()

        // LaunchAgent cold start can place the item under the notch; rebuild once settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.reinstallIfMisplaced()
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func installStatusItem() {
        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "archie.pin"
        item.isVisible = true
        if let button = item.button {
            button.image = nil
            button.title = "A"
            button.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            button.toolTip = "Archie PIN"
            button.appearsDisabled = false
        }
        statusItem = item
        updateButton()
        rebuildMenu()
    }

    private func reinstallIfMisplaced() {
        guard let frame = statusItem?.button?.window?.frame else {
            installStatusItem()
            return
        }
        let screenWidth = NSScreen.main?.frame.width ?? 1500
        let midBand = screenWidth * 0.35 ... screenWidth * 0.65
        if midBand.contains(frame.origin.x) || frame.origin.x < 20 {
            installStatusItem()
        } else {
            statusItem?.isVisible = true
        }
    }

    private func tick() {
        store?.refresh()
        updateButton()
        rebuildMenuIfNeeded()
    }

    private func updateButton() {
        guard let button = statusItem?.button, let store = store else { return }
        button.title = "A"
        if let pin = store.pin, store.receiverRunning {
            button.toolTip = "Archie PIN \(pin) — click for menu"
        } else if store.receiverRunning {
            button.toolTip = "Archie — waiting for PIN"
        } else {
            button.toolTip = "Archie — receiver stopped"
        }
    }

    private func menuSignature() -> String {
        guard let store else { return "nil" }
        return "\(store.receiverRunning)|\(store.pin ?? "")"
    }

    private func rebuildMenuIfNeeded() {
        let sig = menuSignature()
        guard sig != lastMenuSignature || statusItem?.menu == nil else { return }
        lastMenuSignature = sig
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Archie", action: nil, keyEquivalent: ""))

        if let store = store, let pin = store.pin, store.receiverRunning {
            menu.addItem(NSMenuItem.separator())

            let pinItem = NSMenuItem(
                title: "PIN  \(pin)",
                action: #selector(showPin),
                keyEquivalent: ""
            )
            pinItem.target = self
            menu.addItem(pinItem)

            let showItem = NSMenuItem(
                title: "Show PIN notification",
                action: #selector(showPin),
                keyEquivalent: ""
            )
            showItem.target = self
            menu.addItem(showItem)

            let copyItem = NSMenuItem(
                title: "Copy PIN",
                action: #selector(copyPin),
                keyEquivalent: "c"
            )
            copyItem.target = self
            menu.addItem(copyItem)
        } else if store?.receiverRunning == true {
            menu.addItem(NSMenuItem(
                title: "Receiver running — waiting for PIN…",
                action: nil,
                keyEquivalent: ""
            ))
        } else {
            menu.addItem(NSMenuItem(
                title: "Receiver stopped",
                action: nil,
                keyEquivalent: ""
            ))
            menu.addItem(NSMenuItem(
                title: "Plug in an iPhone to start",
                action: nil,
                keyEquivalent: ""
            ))
        }

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(
            title: "Quit Archie Menu",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        lastMenuSignature = menuSignature()
        statusItem?.menu = menu
    }

    @objc private func showPin() {
        guard let pin = store?.pin, !pin.isEmpty else { return }
        let script = """
        display notification "PIN \(pin)" with title "Archie" subtitle "Enter this PIN on the iPhone"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    @objc private func copyPin() {
        guard let pin = store?.pin else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pin, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
