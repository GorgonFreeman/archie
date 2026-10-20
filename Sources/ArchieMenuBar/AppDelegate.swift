import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var store: PinStore?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = PinStore()
        self.store = store

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Archie") {
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
        }
        item.button?.title = " Archie"
        item.button?.toolTip = "Archie PIN"
        statusItem = item
        fputs("archie-menubar: status item created\n", stderr)
        fflush(stderr)

        updateButton()
        rebuildMenu()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func tick() {
        store?.refresh()
        updateButton()
        rebuildMenu()
    }

    private func updateButton() {
        guard let button = statusItem?.button, let store = store else { return }
        if let pin = store.pin, store.receiverRunning {
            button.title = " \(pin)"
            button.toolTip = "Archie PIN \(pin)"
        } else {
            button.title = " Archie"
            button.toolTip = store.receiverRunning
                ? "Archie — waiting for PIN"
                : "Archie — receiver stopped"
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Archie", action: nil, keyEquivalent: ""))

        if let store = store, let pin = store.pin, store.receiverRunning {
            menu.addItem(NSMenuItem.separator())
            let pinItem = NSMenuItem(
                title: "PIN  \(pin)",
                action: #selector(copyPin),
                keyEquivalent: ""
            )
            pinItem.target = self
            menu.addItem(pinItem)

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

        statusItem?.menu = menu
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
