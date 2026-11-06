import AppKit
import HerdrBarCore
import ServiceManagement

@MainActor
final class StatusItemController {
    private let store: AgentStore
    private let panelController: PanelController
    private let item: NSStatusItem
    private var images: BadgeImages?
    private var badge: StatusBadge?
    private var clock: Timer?
    private var frame = 0
    private var observing: Task<Void, Never>?
    private var themeObserver: Any?

    init(store: AgentStore, panelController: PanelController) {
        self.store = store
        self.panelController = panelController
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        apply()
        // Observing the button's effectiveAppearance loops: the status bar re-applies it while snapshotting replicants.
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.apply(force: true) }
        }
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

    /// Re-renders the frame set when the badge or the menu bar's text color changes; the clock only swaps images.
    private func apply(force: Bool = false) {
        guard let button = item.button else { return }
        let badge = StatusBadge(store.snapshot)
        guard force || badge != self.badge else { return }
        self.badge = badge
        var color = NSColor.labelColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
        }
        let images = BadgeImages(badge, color: color)
        self.images = images
        item.length = images.width
        frame = min(frame, images.frames.count - 1)
        button.image = images.frames[frame]
        button.alphaValue = 1
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
        }
        let description: String
        switch badge.glyph {
        case .unavailable: description = "Herdr unavailable"
        case .quiet: description = "no agents working"
        case .working: description = "working"
        case .alert: description = "blocked"
        }
        let summary = badge.text.isEmpty ? description : "\(badge.text) (\(description))"
        button.toolTip = "HerdrBar: \(summary)"
        button.setAccessibilityTitle(badge.text)
        button.setAccessibilityLabel("HerdrBar \(summary)")
    }

    private func tick() {
        guard let button = item.button, let images, let badge else { return }
        switch badge.glyph {
        case .working:
            frame = (frame + 1) % images.frames.count
            button.image = images.frames[frame]
        case .alert:
            let phase = Date().timeIntervalSinceReferenceDate * 2.2
            button.alphaValue = 0.55 + 0.45 * (0.5 + 0.5 * cos(phase))
        case .quiet, .unavailable:
            break
        }
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
