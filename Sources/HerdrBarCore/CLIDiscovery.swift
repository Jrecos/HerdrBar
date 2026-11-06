import Foundation

public enum Tool: String, Sendable, CaseIterable {
    case core
    case app

    /// `hc` is also shipped as `herdr-core`; Herdr.app accepts either.
    public var names: [String] {
        switch self {
        case .core: ["hc", "herdr-core"]
        case .app: ["herdr-app"]
        }
    }

    /// Herdr.app verifies the core by its version banner, so we do the same.
    public func accepts(version: String) -> Bool {
        switch self {
        case .core: version.hasPrefix("hc ")
        case .app: version.hasPrefix("herdr-app ")
        }
    }
}

/// GUI apps don't inherit the shell PATH, so the search is explicit: a setting, PATH, then the usual install dirs.
public struct CLIDiscovery: Sendable {
    public var explicit: [Tool: String]
    public var path: String
    public var home: String

    public init(explicit: [Tool: String] = [:], path: String, home: String) {
        self.explicit = explicit
        self.path = path
        self.home = home
    }

    public static let fallbackDirectories = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    public func candidates(for tool: Tool) -> [String] {
        var paths: [String] = []
        if let explicit = explicit[tool], !explicit.isEmpty { paths.append(explicit) }
        let directories = path.split(separator: ":").map(String.init)
            + Self.fallbackDirectories.map { $0.replacingOccurrences(of: "~", with: home) }
        for directory in directories where !directory.isEmpty {
            for name in tool.names {
                paths.append((directory as NSString).appendingPathComponent(name))
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
