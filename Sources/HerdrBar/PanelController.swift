import AppKit
import HerdrBarCore
import SwiftUI

/// Borderless, non-activating, so it takes keys without pulling focus from the owner's app.
private final class HackerPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

@MainActor
final class PanelController {
    private let store: AgentStore
    private let selection = PanelSelection()
    private let panel: HackerPanel
    private let hosting: NSHostingView<AnyView>
    private var outsideClick: Any?
    private var resignObserver: Any?
    private var resize: Task<Void, Never>?

    var isOpen: Bool { panel.isVisible }

    init(store: AgentStore) {
        self.store = store
        panel = HackerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
    }

    func toggle(under button: NSStatusBarButton) {
        if isOpen { close() } else { open(under: button) }
    }

    func open(under button: NSStatusBarButton) {
        selection.selected = nil
        selection.hovered = nil
        store.panelOpen = true
        render()
        position(under: button)
        panel.makeKeyAndOrderFront(nil)
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        resize = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.fitWhenSnapshotChanges()
            }
        }
    }

    func close() {
        guard isOpen else { return }
        panel.orderOut(nil)
        store.panelOpen = false
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        outsideClick = nil
        resignObserver = nil
        resize?.cancel()
        resize = nil
        hosting.rootView = AnyView(EmptyView())
    }

    /// Observation keeps the SwiftUI tree live; the root view is set once per open so the entry animation runs once.
    private func render() {
        hosting.rootView = AnyView(
            PanelView(
                store: store,
                selection: selection,
                animate: true,
                open: { [weak self] agent in self?.activate(agent) },
                openHerdr: { [weak self] in
                    self?.close()
                    Herdr.open()
                },
                quit: { NSApp.terminate(nil) },
                now: .now))
    }

    /// Grows downward from the menu bar so the top edge stays anchored.
    private func fit() {
        let height = Layout.height(for: store.snapshot)
        var frame = panel.frame
        guard frame.height != height else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func fitWhenSnapshotChanges() async {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = store.snapshot
            } onChange: {
                continuation.resume()
            }
        }
        guard isOpen else { return }
        fit()
    }

    private func position(under button: NSStatusBarButton) {
        guard let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let height = Layout.height(for: store.snapshot)
        var x = anchor.midX - Layout.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - Layout.width - 8)
        let y = anchor.minY - height - 6
        panel.setFrame(NSRect(x: x, y: y, width: Layout.width, height: height), display: true)
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: selection.move(-1, in: store.agents.ordered())
        case 125: selection.move(1, in: store.agents.ordered())
        case 36, 76:
            if let agent = store.agents.first(where: { $0.id == selection.selected }) { activate(agent) }
        case 53: close()
        default: return false
        }
        return true
    }

    private func activate(_ agent: Agent) {
        store.focus(agent)
        close()
    }
}

enum Herdr {
    static let bundleID = "dev.herdr.app"

    @MainActor static func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
