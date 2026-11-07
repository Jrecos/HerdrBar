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

private func liveRunner(failures: [String: CommandFailure] = [:], listing: String = "herdr-app-ls") -> FakeRunner {
    FakeRunner(
        responses: [
            "ls": fixture(listing),
            "get --json t4": fixture("hc-get-t4"),
            "get --json dev/t7": fixture("hc-get-dev-t7"),
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

    @Test(arguments: [".env migration", "/etc/hosts", "[AUTH] investigate", "#123 fix", "$HOME setup", "+1 support", "_config"])
    func preservesLeadingPunctuation(_ title: String) {
        #expect(TaskTitle.clean(title) == title)
    }

    @Test func emptyBecomesUntitled() {
        #expect(TaskTitle.clean(nil) == "Untitled agent")
        #expect(TaskTitle.clean("   ") == "Untitled agent")
        #expect(TaskTitle.clean("π ⠋ ") == "Untitled agent")
    }
}

@Suite struct InventoryRules {
    private func detail(_ name: String) -> TerminalDetail {
        try! JSONDecoder().decode(TerminalDetail.self, from: fixture(name))
    }

    @Test func listingDeterminesAttentionAndSpace() {
        let listing = try! JSONDecoder().decode(SpaceListing.self, from: fixture("herdr-app-ls"))
        let entries = listing.inventory
        #expect(Set(entries.map(\.address)) == ["t4", "t10", "t11", "dev/t7"])
        let local = entries.first { $0.address == "t4" }!.agent(details: ["t4": detail("hc-get-t4")])
        let remote = entries.first { $0.address == "dev/t7" }!.agent(details: ["dev/t7": detail("hc-get-dev-t7")])
        #expect(local.space == "api-server" && local.machine == nil && local.attention == .working)
        #expect(local.since == Date(timeIntervalSince1970: 1_793_981_404.969))
        #expect(remote.space == "web-app" && remote.machine == "dev" && remote.attention == .idle)
        #expect(remote.since == nil)
        #expect(entries.first { $0.address == "t10" }!.agent(details: ["t10": detail("hc-get-t10")]).attention == .blocked)
        let done = entries.first { $0.address == "t11" }!.agent(details: ["t11": detail("hc-get-t11")])
        #expect(done.attention == .done && done.since == nil)
    }

    @Test func appListedTerminalSurvivesParentAndDeadDetail() {
        let data = Data(#"{"spaces":[{"id":"s","name":"space","tabs":[{"terminals":[{"terminal":"t9","status":"working"}]}]}]}"#.utf8)
        let entry = try! JSONDecoder().decode(SpaceListing.self, from: data).inventory[0]
        let childDetail = detail("hc-get-t9")
        #expect(entry.agent(details: ["t9": childDetail]).address == "t9")
        let dead = Data(#"{"address":"t9","parent":null,"state":"dead","status":{"state":"working"},"title":"Stopped","status_ms":1000}"#.utf8)
        let deadDetail = try! JSONDecoder().decode(TerminalDetail.self, from: dead)
        #expect(entry.agent(details: ["t9": deadDetail]).task == "Stopped")
    }

    @Test func unknownStatusRemainsVisibleWithoutInventingAge() {
        let data = Data(#"{"spaces":[{"id":"s","name":"space","tabs":[{"terminals":[{"terminal":"t4","status":"future"}]}]}]}"#.utf8)
        let entry = try! JSONDecoder().decode(SpaceListing.self, from: data).inventory[0]
        let agent = entry.agent(details: ["t4": detail("hc-get-t4")])
        #expect(agent.attention == .unknown && agent.since == nil)
        #expect([agent].grouped().map(\.attention) == [.unknown])
    }
}

@Suite struct Grouping {
    private func agent(_ address: String, _ space: String, _ attention: Attention) -> Agent {
        Agent(address: address, space: space, machine: nil, task: "", attention: attention, since: .now, runningSubagentCount: nil)
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
            Agent(address: "t", space: "", machine: nil, task: "", attention: .idle, since: now.addingTimeInterval(-seconds), runningSubagentCount: nil)
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
            Agent(address: "t1", space: "a", machine: nil, task: "", attention: .working, since: .now, runningSubagentCount: nil),
            Agent(address: "t2", space: "a", machine: nil, task: "", attention: .idle, since: .now, runningSubagentCount: nil),
        ]
        #expect(tracker.record(first).isEmpty)
        let second = [
            Agent(address: "t1", space: "a", machine: nil, task: "", attention: .done, since: .now, runningSubagentCount: nil),
            Agent(address: "t2", space: "a", machine: nil, task: "", attention: .idle, since: .now, runningSubagentCount: nil),
            Agent(address: "t3", space: "a", machine: nil, task: "", attention: .blocked, since: .now, runningSubagentCount: nil),
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
    }

    @Test func missingCLIIsUnavailable() async {
        let runner = FakeRunner(versions: [:])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot.failure?.hasPrefix("herdr-app: not found") == true)
    }

    @Test func wrongVersionBannerIsRejected() async {
        let runner = FakeRunner(responses: ["ls": fixture("herdr-app-ls")], versions: [hc: "herdr-app 0.1.13", app: "herdr-app 0.1.13"])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot.failure == nil)
        #expect(snapshot.agents.allSatisfy { $0.task == "Task unavailable" && $0.since == nil })
    }

    @Test func failingCommandReportsItsStderr() async {
        let runner = liveRunner(failures: ["ls": CommandFailure(command: "herdr-app ls", reason: "app is not running")])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot == .unavailable("herdr-app ls: app is not running"))
    }

    @Test func appInventorySurvivesMissingCoreMachineAndFailedDetails() async {
        let runner = liveRunner(failures: [
            "ls --json": CommandFailure(command: "hc ls --json", reason: "remote machine omitted"),
            "get --json dev/t7": CommandFailure(command: "hc get", reason: "registry writer stopped"),
            "get --json dev/t12": CommandFailure(command: "hc get", reason: "registry writer stopped"),
        ], listing: "herdr-app-remote-failure")
        let snapshot = await client(runner).snapshot()
        let remote = snapshot.agents.filter { $0.machine == "dev" }
        #expect(Set(remote.map(\.address)) == ["dev/t7", "dev/t12"])
        #expect(remote.first { $0.address == "dev/t7" }?.attention == .idle)
        #expect(remote.first { $0.address == "dev/t12" }?.attention == .working)
        #expect(remote.allSatisfy { $0.task == "Task unavailable" && $0.since == nil && $0.age(at: .now) == "age unavailable" })
        #expect(remote.allSatisfy { $0.space == "web-app" })
        #expect(!runner.calls.contains { $0.dropFirst().elementsEqual(["ls", "--json"]) })
    }

    @Test func appStatusWinsOverStaleDetailWithoutInventingAge() async {
        let listing = Data(#"{"spaces":[{"id":"s","name":"space","machine":null,"tabs":[{"terminals":[{"terminal":"t4","status":"idle"}]}]}]}"#.utf8)
        let runner = FakeRunner(responses: ["ls": listing, "get --json t4": fixture("hc-get-t4")],
                                versions: [hc: "hc 0.1.18", app: "herdr-app 0.1.13"])
        let agent = await client(runner).snapshot().agents.first
        #expect(agent?.attention == .idle)
        #expect(agent?.since == nil)
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
            Agent(address: "t\($0.offset)", space: "", machine: nil, task: "", attention: $0.element, since: .now, runningSubagentCount: nil)
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
        #expect(mixed.first?.age(at: now) == "10m")
        #expect(mixed.map(\.runningSubagentCount) == [2, 0, 4, nil, 0, 0])
        #expect(try Fixture.load(root.appendingPathComponent("empty.json"), now: now).isEmpty)
    }
}

@Suite struct SubagentCounts {
    private func data(_ value: String) -> Data { Data(value.utf8) }

    private func runner(listing: Data, details: [String: String], coreAvailable: Bool = true) -> FakeRunner {
        var responses = details.reduce(into: [String: Data]()) {
            $0["get --json \($1.key)"] = data($1.value)
        }
        responses["ls"] = listing
        var versions = [app: "herdr-app 0.1.13"]
        if coreAvailable { versions[hc] = "hc 0.1.18" }
        return FakeRunner(responses: responses, versions: versions)
    }

    private func listing(children: String = "[]") -> Data {
        data(#"{"spaces":[{"id":"s","name":"space","tabs":[{"terminals":[{"terminal":"t1","status":"blocked","sub_agents":\#(children)}]}]}]}"#)
    }

    @Test func countsRecordsAndUniqueDirectChildrenWithoutChangingAttention() async {
        let runner = runner(listing: fixture("herdr-app-subagents"), details: [
            "t1": #"{"address":"t1","state":"live","status":{"state":"idle"},"records":{"build/test":{"state":"working"},"b":{"state":"working"},"c":{"state":"done"},"d":{"state":"idle"},"e":{"state":"blocked"},"f":{"state":"error"}}}"#,
            "t2": #"{"address":"t2","state":"live","status":{"state":"done"}}"#,
            "dev/t1": #"{"address":"dev/t1","state":"finished","records":{"stale":{"state":"working"}}}"#,
            "t3": #"{"address":"t3","state":"live","status":{"state":"working"}}"#,
            "t7": #"{"address":"t7","parent":"other-normalization","state":"live","status":{"state":"working"},"records":{"nested":{"state":"working"}}}"#,
            "dev/t7": #"{"address":"dev/t7","state":"live","status":{"state":"done"}}"#,
            "t8": #"{"address":"t8","state":"live","status":{"state":"idle"}}"#,
            "t9": #"{"address":"t9","state":"live","status":{"state":"blocked"}}"#,
            "t10": #"{"address":"t10","state":"live","status":null}"#,
            "t11": #"{"address":"t11","state":"finished","status":{"state":"working"}}"#,
        ])
        let snapshot = await client(runner).snapshot()
        let rows = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.address, $0) })
        #expect(snapshot.failure == nil && rows.count == 5)
        #expect(rows["t1"]?.attention == .idle && rows["t1"]?.runningSubagentCount == 3)
        #expect(rows["t2"]?.attention == .done && rows["t2"]?.runningSubagentCount == 1)
        #expect(rows["dev/t1"]?.attention == .blocked && rows["dev/t1"]?.runningSubagentCount == 1)
        #expect(rows["t7"]?.runningSubagentCount == 1)
        #expect(rows["t3"]?.runningSubagentCount == 0)
        for address in ["t7", "dev/t7"] {
            #expect(runner.calls.filter { $0 == [hc, "get", "--json", address] }.count == 1)
        }
    }

    @Test(arguments: ["null", "{}", #"[{"terminal":"t7"}]"#, #"["t7",2]"#])
    func malformedOptionalMembershipKeepsRow(_ children: String) async {
        let runner = runner(listing: listing(children: children), details: [
            "t1": #"{"address":"t1","state":"live"}"#,
        ])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot.failure == nil && snapshot.agents.count == 1)
        #expect(snapshot.agents[0].attention == .blocked)
        #expect(snapshot.agents[0].runningSubagentCount == nil)
    }

    @Test(arguments: [
        #"{"address":"t7","state":"live","status":{"state":"future"}}"#,
        #"{"address":"t7","state":"future","status":{"state":"working"}}"#,
        #"{"address":"other/t7","state":"live","status":{"state":"working"}}"#,
        "not JSON", "",
    ])
    func unavailableChildCannotProducePartialCount(_ child: String) async {
        let runner = runner(listing: listing(children: #"["t7"]"#), details: [
            "t1": #"{"address":"t1","state":"live","title":"Still visible","records":{"a":{"state":"working"}}}"#,
            "t7": child,
        ])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot.failure == nil && snapshot.agents.count == 1)
        #expect(snapshot.agents[0].task == "Still visible")
        #expect(snapshot.agents[0].attention == .blocked)
        #expect(snapshot.agents[0].runningSubagentCount == nil)
    }

    @Test(arguments: [
        #"{"address":"t1","state":"future"}"#,
        #"{"address":"t1","state":"live","records":{"a":{"state":"future"}}}"#,
        #"{"address":"dev/t1","state":"live"}"#,
        "not JSON", "",
    ])
    func unavailableParentPreservesInventory(_ parent: String) async {
        let runner = runner(listing: listing(), details: ["t1": parent])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot.failure == nil && snapshot.agents.count == 1)
        #expect(snapshot.agents[0].attention == .blocked)
        #expect(snapshot.agents[0].runningSubagentCount == nil)
    }

    @Test func missingParentChildAndCoreStayUnknown() async {
        for runner in [
            runner(listing: listing(), details: [:]),
            runner(listing: listing(children: #"["t7"]"#), details: ["t1": #"{"address":"t1","state":"live"}"#]),
            runner(listing: listing(), details: [:], coreAvailable: false),
            runner(listing: fixture("herdr-app-remote-failure"), details: [:]),
        ] {
            let snapshot = await client(runner).snapshot()
            #expect(snapshot.failure == nil && !snapshot.agents.isEmpty)
            #expect(snapshot.agents.allSatisfy { $0.runningSubagentCount == nil })
        }
    }

    @Test func finishedParentSuppressesStaleRecords() async {
        let runner = runner(listing: listing(), details: [
            "t1": #"{"address":"t1","state":"finished","records":{"stale":{"state":"future"}}}"#,
        ])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot.agents.first?.runningSubagentCount == 0)
    }

    @Test func missingMembershipIsUnknownAndMissingRecordsAreEmpty() async {
        let runner = runner(listing: data(#"{"spaces":[{"id":"s","name":"space","tabs":[{"terminals":[{"terminal":"t1","status":"idle"},{"terminal":"t2","status":"working","sub_agents":[]}]}]}]}"#), details: [
            "t1": #"{"address":"t1","state":"live"}"#,
            "t2": #"{"address":"t2","state":"live","status":{"state":"working"}}"#,
        ])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot.agents.first { $0.address == "t1" }?.runningSubagentCount == nil)
        #expect(snapshot.agents.first { $0.address == "t2" }?.runningSubagentCount == 0)
    }

    @Test func legacyFixtureAndAgentJSONDecodeWithoutCount() throws {
        let legacy = data(#"{"agents":[{"address":"t1","space":"space","task":"task","attention":"idle","age_minutes":0}]}"#)
        let fixture = try JSONDecoder().decode(Fixture.self, from: legacy)
        #expect(fixture.agents(now: .now)[0].runningSubagentCount == nil)
        let agent = try JSONDecoder().decode(Agent.self, from: data(#"{"address":"t1","space":"space","task":"task","attention":"idle"}"#))
        #expect(agent.runningSubagentCount == nil)
        let positive = Agent(address: "t1", space: "space", machine: nil, task: "task", attention: .idle, since: nil, runningSubagentCount: 2)
        #expect(try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(positive)) == positive)
    }

    @Test func countOnlyUpdateDoesNotFlashOrChangeMenuBarTotals() {
        let first = Agent(address: "t1", space: "space", machine: nil, task: "", attention: .idle, since: nil, runningSubagentCount: 0)
        let second = Agent(address: "t1", space: "space", machine: nil, task: "", attention: .idle, since: nil, runningSubagentCount: 2)
        var tracker = AttentionTracker()
        #expect(tracker.record([first]).isEmpty)
        #expect(tracker.record([second]).isEmpty)
        #expect([first].counts == [second].counts)
    }
}

@Suite struct RemoteSubagentIdentity {
    @Test func remoteAndLocalChildrenKeepIndependentStates() async {
        let listing = Data(#"{"spaces":[{"id":"s","name":"space","machine":"dev","tabs":[{"terminals":[{"terminal":"dev/t1","status":"done","sub_agents":["dev/t7","t7"]}]}]}]}"#.utf8)
        let runner = FakeRunner(responses: [
            "ls": listing,
            "get --json dev/t1": Data(#"{"address":"dev/t1","state":"live","status":{"state":"done"}}"#.utf8),
            "get --json dev/t7": Data(#"{"address":"dev/t7","parent":"t1","state":"live","status":{"state":"working"}}"#.utf8),
            "get --json t7": Data(#"{"address":"t7","state":"live","status":{"state":"error"}}"#.utf8),
        ], versions: [hc: "hc 0.1.18", app: "herdr-app 0.1.13"])
        let snapshot = await client(runner).snapshot()
        #expect(snapshot.agents.count == 1)
        #expect(snapshot.agents[0].address == "dev/t1")
        #expect(snapshot.agents[0].machine == "dev")
        #expect(snapshot.agents[0].attention == .done)
        #expect(snapshot.agents[0].runningSubagentCount == 1)
    }
}
