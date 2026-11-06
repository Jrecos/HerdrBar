import Foundation
import Testing
@testable import HerdrBarCore

private func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

/// Serves fixture files keyed by the command's arguments and records every call.
private final class FakeRunner: CommandRunner, @unchecked Sendable {
    let responses: [String: Data]
    let failures: [String: CommandFailure]
    let versions: [String: String]
    private let lock = NSLock()
    private(set) var calls: [[String]] = []

    init(responses: [String: Data] = [:], failures: [String: CommandFailure] = [:], versions: [String: String] = [:]) {
        self.responses = responses
        self.failures = failures
        self.versions = versions
    }

    func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        lock.withLock { calls.append([executable] + arguments) }
        if arguments == ["--version"] {
            if let banner = versions[executable] { return Data(banner.utf8) }
            throw CommandFailure(command: executable, reason: "no such file")
        }
        let key = arguments.joined(separator: " ")
        if let failure = failures[key] { throw failure }
        guard let data = responses[key] else { throw CommandFailure(command: key, reason: "unexpected call") }
        return data
    }
}

private let hc = "/usr/bin/true"
private let app = "/usr/bin/false"

private func client(_ runner: FakeRunner) -> HerdrClient {
    HerdrClient(runner: runner, discovery: CLIDiscovery(explicit: [.core: hc, .app: app], path: "", home: "/nonexistent"))
}

private func liveRunner(failures: [String: CommandFailure] = [:]) -> FakeRunner {
    FakeRunner(
        responses: [
            "ls --json": fixture("hc-ls"),
            "ls": fixture("herdr-app-ls"),
            "get --json t4": fixture("hc-get-t4"),
            "get --json dev/t7": fixture("hc-get-dev-t7"),
            "get --json t9": fixture("hc-get-t9"),
            "get --json t10": fixture("hc-get-t10"),
            "get --json t11": fixture("hc-get-t11"),
        ],
        failures: failures,
        versions: [hc: "hc 0.1.18\n", app: "herdr-app 0.1.13\n"])
}

@Suite struct TitleCleaning {
    @Test func stripsOmpPrefixSpinnerAndGlyph() {
        #expect(TaskTitle.clean("π ⠴ \u{E0B0} DOCS: Write the install guide") == "DOCS: Write the install guide")
        #expect(TaskTitle.clean("π > AUTH: Session routing") == "AUTH: Session routing")
        #expect(TaskTitle.clean("π ✗ DEPLOY: Approval needed") == "DEPLOY: Approval needed")
    }

    @Test func keepsPlainTitlesAndCollapsesWhitespace() {
        #expect(TaskTitle.clean("Ready   for\tthe next task") == "Ready for the next task")
        #expect(TaskTitle.clean("42 things") == "42 things")
    }

    @Test func emptyBecomesUntitled() {
        #expect(TaskTitle.clean(nil) == "Untitled agent")
        #expect(TaskTitle.clean("   ") == "Untitled agent")
        #expect(TaskTitle.clean("π ⠋ ") == "Untitled agent")
    }
}

@Suite struct AttentionRules {
    private func detail(_ name: String) -> TerminalDetail {
        try! JSONDecoder().decode(TerminalDetail.self, from: fixture(name))
    }

    @Test func workingStaysWorking() {
        #expect(detail("hc-get-t4").attention == .working)
    }

    @Test func idleWithTurnAtSeenIsIdle() {
        #expect(detail("hc-get-dev-t7").attention == .idle)
    }

    @Test func doneWithUnseenTurnIsDone() {
        #expect(detail("hc-get-t11").attention == .done)
    }

    @Test func errorMapsToBlocked() {
        #expect(detail("hc-get-t10").attention == .blocked)
    }

    @Test func subAgentsAreSkipped() {
        #expect(detail("hc-get-t9").agent(spaces: [:]) == nil)
    }

    @Test func remoteSpaceResolvesThroughMachineQualifiedID() {
        let spaces = try! JSONDecoder().decode(SpaceListing.self, from: fixture("herdr-app-ls")).namesByID
        let agent = detail("hc-get-dev-t7").agent(spaces: spaces)
        #expect(agent?.space == "web-app")
        #expect(agent?.machine == "dev")
        let local = detail("hc-get-t4").agent(spaces: spaces)
        #expect(local?.space == "api-server")
        #expect(local?.machine == nil)
        #expect(local?.since == Date(timeIntervalSince1970: 1_793_981_404.969))
    }

    @Test func unknownSpaceFallsBackToID() {
        #expect(detail("hc-get-t4").agent(spaces: [:])?.space == "spAPI")
    }
}

@Suite struct Grouping {
    private func agent(_ address: String, _ space: String, _ attention: Attention) -> Agent {
        Agent(address: address, space: space, machine: nil, task: "", attention: attention, since: .now)
    }

    @Test func groupsFollowAttentionOrderAndSkipEmptyOnes() {
        let agents = [
            agent("t3", "zeta", .idle), agent("t1", "beta", .working), agent("t2", "Alpha", .working),
            agent("t5", "beta", .blocked),
        ]
        let groups = agents.grouped()
        #expect(groups.map(\.attention) == [.blocked, .working, .idle])
        #expect(groups[1].agents.map(\.address) == ["t2", "t1"])
        #expect(agents.counts == Counts(blocked: 1, done: 0, working: 2, idle: 1))
    }

    @Test func sameSpaceSortsByAddress() {
        let agents = [agent("t9", "home", .idle), agent("dev/t1", "home", .idle), agent("t2", "home", .idle)]
        #expect(agents.ordered().map(\.address) == ["dev/t1", "t2", "t9"])
    }
}

@Suite struct Ages {
    @Test func agesRoundDownByUnit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func age(_ seconds: Double) -> String {
            Agent(address: "t", space: "", machine: nil, task: "", attention: .idle, since: now.addingTimeInterval(-seconds))
                .age(at: now)
        }
        #expect(age(30) == "<1m")
        #expect(age(-30) == "<1m")
        #expect(age(59 * 60) == "59m")
        #expect(age(60 * 60) == "1h")
        #expect(age(23 * 3600 + 59 * 60) == "23h")
        #expect(age(3 * 86400 + 5 * 3600) == "3d")
    }
}

@Suite struct AttentionTracking {
    @Test func reportsOnlyAddressesWhoseAttentionChanged() {
        var tracker = AttentionTracker()
        let first = [
            Agent(address: "t1", space: "a", machine: nil, task: "", attention: .working, since: .now),
            Agent(address: "t2", space: "a", machine: nil, task: "", attention: .idle, since: .now),
        ]
        #expect(tracker.record(first).isEmpty)
        let second = [
            Agent(address: "t1", space: "a", machine: nil, task: "", attention: .done, since: .now),
            Agent(address: "t2", space: "a", machine: nil, task: "", attention: .idle, since: .now),
            Agent(address: "t3", space: "a", machine: nil, task: "", attention: .blocked, since: .now),
        ]
        #expect(tracker.record(second) == ["t1"])
        #expect(tracker.record(second).isEmpty)
    }
}

@Suite struct Discovery {
    @Test func searchOrderIsSettingThenPathThenFallbacks() {
        let discovery = CLIDiscovery(explicit: [.core: "/custom/hc"], path: "/a:/b", home: "/home/me")
        #expect(discovery.candidates(for: .core) == [
            "/custom/hc", "/a/hc", "/a/herdr-core", "/b/hc", "/b/herdr-core",
            "/home/me/.local/bin/hc", "/home/me/.local/bin/herdr-core",
            "/opt/homebrew/bin/hc", "/opt/homebrew/bin/herdr-core",
            "/usr/local/bin/hc", "/usr/local/bin/herdr-core",
        ])
        #expect(discovery.candidates(for: .app).first == "/a/herdr-app")
    }

    @Test func emptyPathStillSearchesFallbacks() {
        let discovery = CLIDiscovery(path: "", home: "/home/me")
        #expect(discovery.candidates(for: .app) == [
            "/home/me/.local/bin/herdr-app", "/opt/homebrew/bin/herdr-app", "/usr/local/bin/herdr-app",
        ])
    }

    @Test func requiresTheVersionBanner() {
        #expect(Tool.core.accepts(version: "hc 0.2.0\n"))
        #expect(!Tool.core.accepts(version: "hcx 1.0"))
        #expect(!Tool.core.accepts(version: "herdr-app 0.1.13"))
        #expect(Tool.app.accepts(version: "herdr-app 0.1.13\n"))
        #expect(!Tool.app.accepts(version: "hc 0.1.18"))
    }
}

@Suite struct ClientSnapshots {
    @Test func liveSnapshotPortsThePluginRules() async {
        let runner = liveRunner()
        let snapshot = await client(runner).snapshot()
        let agents = snapshot.agents.ordered()
        #expect(agents.map(\.address) == ["t10", "t11", "t4", "dev/t7"])
        #expect(agents.map(\.attention) == [.blocked, .done, .working, .idle])
        #expect(agents[0].task == "DEPLOY: Approval needed before restarting the gateway")
        #expect(agents[1].task == "Untitled agent")
        #expect(agents[3].space == "web-app")
        let fetched = runner.calls.filter { $0[1] == "get" }.map { $0[3] }
        #expect(Set(fetched) == ["t4", "dev/t7", "t9", "t10", "t11"])
    }

    @Test func missingCLIIsUnavailable() async {
        let runner = FakeRunner(versions: [:])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot.failure?.hasPrefix("hc: not found") == true)
    }

    @Test func wrongVersionBannerIsRejected() async {
        let runner = FakeRunner(versions: [hc: "herdr-app 0.1.13", app: "herdr-app 0.1.13"])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot.failure?.hasPrefix("hc: not found") == true)
    }

    @Test func failingCommandReportsItsStderr() async {
        let runner = liveRunner(failures: ["ls --json": CommandFailure(command: "hc ls --json", reason: "core is not running")])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot == .unavailable("hc ls --json: core is not running"))
    }

    @Test func focusSendsTheHerdrCommand() async throws {
        let runner = liveRunner(failures: [:])
        let runnerWithFocus = FakeRunner(
            responses: ["do agent.focus {\"terminal\":\"dev/t7\"}": Data()],
            versions: runner.versions)
        try await client(runnerWithFocus).focus("dev/t7")
        #expect(runnerWithFocus.calls.last == [app, "do", "agent.focus", "{\"terminal\":\"dev/t7\"}"])
    }
}

@Suite struct Badges {
    private func snapshot(_ attentions: [Attention]) -> Snapshot {
        .loaded(attentions.enumerated().map {
            Agent(address: "t\($0.offset)", space: "", machine: nil, task: "", attention: $0.element, since: .now)
        })
    }

    @Test func blockedWinsAndCountsStack() {
        let badge = StatusBadge(snapshot([.blocked, .working, .working, .done]), spinnerFrame: 3)
        #expect(badge.glyph == .alert)
        #expect(badge.text == "!1 2 ✓1")
    }

    @Test func workingSpinsAndWrapsFrames() {
        #expect(StatusBadge(snapshot([.working]), spinnerFrame: 11).glyph == .working("⠙"))
        #expect(StatusBadge(snapshot([.working, .done]), spinnerFrame: 0).text == "1 ✓1")
    }

    @Test func quietAndUnavailable() {
        #expect(StatusBadge(snapshot([.idle])) == StatusBadge(snapshot([])))
        #expect(StatusBadge(snapshot([])).glyph == .quiet)
        #expect(StatusBadge(.unavailable("x")).glyph == .unavailable)
    }
}

@Suite struct Fixtures {
    @Test func docsFixturesLoadWithRelativeAges() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/fixtures")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let mixed = try Fixture.load(root.appendingPathComponent("mixed.json"), now: now)
        #expect(Set(mixed.map(\.attention)) == Set(Attention.allCases))
        #expect(mixed.contains { $0.machine != nil })
        #expect(mixed.first?.age(at: now) == "10m")
        #expect(try Fixture.load(root.appendingPathComponent("empty.json"), now: now).isEmpty)
    }
}
