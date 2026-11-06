import AppKit
import HerdrBarCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AgentStore?
    private var panel: PanelController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = AgentStore.live()
        let panel = PanelController(store: store)
        self.store = store
        self.panel = panel
        statusItem = StatusItemController(store: store, panelController: panel)
        store.start()
    }
}

/// `--snapshot <out.png> [--fixture <agents.json>]` renders the panel at 2x and exits; screen capture isn't an option for agents.
@MainActor
func renderSnapshot(to output: String, fixture: String?) async throws {
    let now = Date(timeIntervalSince1970: 1_793_980_800)
    let snapshot: Snapshot
    if let fixture {
        snapshot = .loaded(try Fixture.load(URL(fileURLWithPath: fixture), now: now))
    } else {
        snapshot = await AgentStore.live().clientSnapshot()
    }
    let store = AgentStore(client: HerdrClient(runner: ProcessRunner(), discovery: CLIDiscovery(path: "", home: "")), initial: snapshot)
    let view = PanelView(
        store: store, selection: PanelSelection(), animate: false,
        open: { _ in }, openHerdr: {}, quit: {}, now: fixture == nil ? Date() : now)
        .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CommandFailure(command: "--snapshot", reason: "panel rendering failed")
    }
    try png.write(to: URL(fileURLWithPath: output))
}

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
    let fixture = arguments.firstIndex(of: "--fixture").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    _ = NSApplication.shared
    do {
        try await renderSnapshot(to: arguments[index + 1], fixture: fixture)
        print("wrote \(arguments[index + 1])")
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
