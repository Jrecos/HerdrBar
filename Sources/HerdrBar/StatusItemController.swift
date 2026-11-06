import AppKit
import HerdrBarCore
import ServiceManagement

@MainActor
final class StatusItemController {
    private let store: AgentStore
    private let panelController: PanelController
    private let item: NSStatusItem
    private var clock: Timer?
    private var frame = 0
    private var observing: Task<Void, Never>?
    private var glyphCache: [Character: NSImage] = [:]

    init(store: AgentStore, panelController: PanelController) {
        self.store = store
        self.panelController = panelController
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.font = NSFont.menuBarFont(ofSize: 0)
        apply()
        observing = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.applyWhenSnapshotChanges()
            }
        }
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            panelController.close()
            showMenu()
        } else {
            panelController.toggle(under: button)
        }
    }

    private func applyWhenSnapshotChanges() async {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = store.snapshot
            } onChange: {
                continuation.resume()
            }
        }
        apply()
    }

    /// One 10 Hz clock drives both the spinner and the alert pulse; it stops when neither is on screen.
    private func apply() {
        let badge = StatusBadge(store.snapshot, spinnerFrame: frame)
        let animated: Bool
        switch badge.glyph {
        case .working, .alert: animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        case .quiet, .unavailable: animated = false
        }
        if animated, clock == nil {
            clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } else if !animated, let clock {
            clock.invalidate()
            self.clock = nil
            frame = 0
            item.button?.alphaValue = 1
        }
        draw(badge)
    }

    private func tick() {
        frame = (frame + 1) % spinnerFrames.count
        let badge = StatusBadge(store.snapshot, spinnerFrame: frame)
        if case .alert = badge.glyph {
            let phase = Date().timeIntervalSinceReferenceDate * 2.2
            item.button?.alphaValue = 0.6 + 0.4 * (0.5 + 0.5 * cos(phase))
        } else {
            draw(badge)
        }
    }

    private func draw(_ badge: StatusBadge) {
        guard let button = item.button else { return }
        let description: String
        switch badge.glyph {
        case .unavailable:
            button.image = symbol("terminal", size: 14)
            button.contentTintColor = nil
            button.appearsDisabled = true
            description = "Herdr unavailable"
        case .quiet:
            button.image = symbol("terminal", size: 14)
            button.contentTintColor = nil
            button.appearsDisabled = false
            description = "no agents working"
        case .working(let spinner):
            button.image = glyph(spinner)
            button.contentTintColor = nil
            button.appearsDisabled = false
            description = "working"
        case .alert:
            button.image = symbol("exclamationmark.triangle.fill", size: 13)
            button.contentTintColor = Phosphor.blockedNS
            button.appearsDisabled = false
            description = "blocked"
        }
        button.title = badge.text.isEmpty ? "" : " \(badge.text)"
        let summary = badge.text.isEmpty ? description : "\(badge.text) (\(description))"
        button.toolTip = "HerdrBar: \(summary)"
        button.setAccessibilityLabel("HerdrBar \(summary)")
        if case .alert = badge.glyph {} else { button.alphaValue = 1 }
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        image?.isTemplate = true
        return image
    }

    /// Braille frames drawn as template images so the menu bar tints them like any symbol.
    private func glyph(_ character: Character) -> NSImage {
        if let cached = glyphCache[character] { return cached }
        let font = Mono.nsFont(15)
        let string = NSAttributedString(string: String(character), attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let bounds = string.boundingRect(with: rect.size, options: [])
            string.draw(at: NSPoint(x: (rect.width - bounds.width) / 2, y: (rect.height - bounds.height) / 2 - 1))
            return true
        }
        image.isTemplate = true
        glyphCache[character] = image
        return image
    }

    private func showMenu() {
        let menu = NSMenu()
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let open = NSMenuItem(title: "Open Herdr", action: #selector(openHerdr), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit HerdrBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at login: %@", error.localizedDescription)
        }
    }

    @objc private func openHerdr() {
        Herdr.open()
    }
}
