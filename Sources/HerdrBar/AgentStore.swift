import AppKit
import Foundation
import HerdrBarCore
import Observation

@MainActor @Observable
final class AgentStore {
    private(set) var snapshot: Snapshot = .loaded([])
    private(set) var changed: Set<String> = []
    private(set) var focusFailure: String?
    private(set) var closeFailure: String?
    var panelOpen = false {
        didSet { if panelOpen != oldValue { refreshNow() } }
    }

    private let client: HerdrClient
    private var tracker = AttentionTracker()
    private var loop: Task<Void, Never>?
    private var ticket = 0

    init(client: HerdrClient, initial: Snapshot = .loaded([])) {
        self.client = client
        snapshot = initial
    }

    static func live() -> AgentStore {
        let defaults = UserDefaults.standard
        var explicit: [Tool: String] = [:]
        for tool in Tool.allCases {
            if let path = defaults.string(forKey: tool.settingKey), !path.isEmpty { explicit[tool] = path }
        }
        let discovery = CLIDiscovery(
            explicit: explicit,
            path: ProcessInfo.processInfo.environment["PATH"] ?? "",
            home: NSHomeDirectory())
        return AgentStore(client: HerdrClient(runner: ProcessRunner(), discovery: discovery))
    }

    var agents: [Agent] { snapshot.agents }

    func clientSnapshot() async -> Snapshot {
        await client.snapshot()
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: .seconds(panelOpen ? 2 : 5))
            }
        }
    }

    /// Restarts the loop so the new interval applies at once.
    private func refreshNow() {
        loop?.cancel()
        loop = nil
        start()
    }

    private func refresh() async {
        ticket += 1
        let mine = ticket
        let next = await client.snapshot()
        guard mine == ticket else { return }
        if case .loaded(let agents) = next {
            changed = tracker.record(agents)
        }
        snapshot = next
    }

    func focus(_ agent: Agent) {
        closeFailure = nil
        focusFailure = nil
        Task {
            do {
                if let herdr = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Herdr.bundleID) {
                    _ = try await NSWorkspace.shared.openApplication(at: herdr, configuration: NSWorkspace.OpenConfiguration())
                }
                try await client.focus(agent.address)
            } catch {
                focusFailure = "\(error)"
            }
        }
    }

    func close(_ agent: Agent) {
        focusFailure = nil
        closeFailure = nil
        Task {
            do {
                try await client.close(agent.closeTarget)
            } catch {
                closeFailure = "\(error)"
            }
            refreshNow()
        }
    }
}
