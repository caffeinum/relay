import Foundation

public enum ConfigError: Error, CustomStringConvertible {
    case missing(String)
    case unknownWorkspace(String, [String])
    case noToken(workspace: String, account: String)
    case inlineTokenForSlack(String)

    public var description: String {
        switch self {
        case .missing(let p): return "no config at \(p). run `\(Brand.cli) init` to write one"
        case .unknownWorkspace(let w, let known): return "workspace \(w) is not in the config (known: \(known.joined(separator: ", ")))"
        case .noToken(let w, let a): return "no user token for \(w): keychain item service=\(Brand.keychainService) account=\(a) is missing"
        case .inlineTokenForSlack(let w): return "workspace \(w) talks to slack.com but has a token in the config file. real tokens live in the keychain only"
        }
    }
}

/// ~/.config/<slug>/config.json. Workspaces are config, never UI: the app
/// shows the current one, and ⌘K switches.
public struct Config: Codable, Equatable {
    public struct Workspace: Codable, Equatable {
        /// Base of the Web API, e.g. https://slack.com/api or an emulator.
        public var api: String
        /// Only for emulators: a fake token kept in the file. Real workspaces
        /// read theirs from the keychain.
        public var token: String?
        /// Writes (send, edit, react, mark) stay off until the owner says so.
        public var writes: Bool?
        /// Only for emulators: a fake Socket Mode (xapp) token.
        public var appToken: String?

        public init(api: String, token: String? = nil, writes: Bool? = nil, appToken: String? = nil) {
            self.api = api; self.token = token; self.writes = writes; self.appToken = appToken
        }

        public var isSlack: Bool { URL(string: api)?.host?.hasSuffix("slack.com") ?? false }
    }

    /// A sidebar section kept locally, since Slack's API doesn't expose them.
    public struct Section: Codable, Equatable {
        public var name: String
        public var channels: [String]
        public var collapsed: Bool?
        public var emoji: String?
        public init(name: String, channels: [String], collapsed: Bool? = nil, emoji: String? = nil) {
            self.name = name; self.channels = channels; self.collapsed = collapsed; self.emoji = emoji
        }
    }

    public var workspace: String
    public var workspaces: [String: Workspace]
    public var sections: [Section]?
    /// The outbox's undo window (O1); 5 s when absent.
    public var undoSeconds: Double?
    /// Timestamps with seconds (K-3 toggle).
    public var showSeconds: Bool?

    public static let defaultUndoSeconds: Double = 5

    public init(workspace: String, workspaces: [String: Workspace], sections: [Section]? = nil, undoSeconds: Double? = nil, showSeconds: Bool? = nil) {
        self.workspace = workspace; self.workspaces = workspaces; self.sections = sections
        self.undoSeconds = undoSeconds; self.showSeconds = showSeconds
    }

    /// Reads the file fresh, changes it and writes it back atomically, so
    /// edits made by hand since launch survive a toggle.
    public static func update(at url: URL = Paths.config, _ change: (inout Config) -> Void) throws -> Config {
        var c = try load(from: url)
        change(&c)
        try c.save(to: url)
        return c
    }

    public static let starter = Config(
        workspace: "emulator",
        workspaces: [
            "2027dev": Workspace(api: "https://slack.com/api"),
            "emulator": Workspace(api: "http://localhost:4003/api", token: "xoxp-emu-aleks", writes: true, appToken: "xapp-emu-relay"),
        ],
        sections: [Section(name: "Customers", channels: ["customers"])])

    public static func load(from url: URL = Paths.config) throws -> Config {
        guard let d = try? Data(contentsOf: url) else { throw ConfigError.missing(url.path) }
        return try JSONDecoder().decode(Config.self, from: d)
    }

    public func save(to url: URL = Paths.config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }

    public func current(_ name: String? = nil) throws -> (String, Workspace) {
        let n = name ?? workspace
        guard let w = workspaces[n] else { throw ConfigError.unknownWorkspace(n, workspaces.keys.sorted()) }
        return (n, w)
    }

    public static func keychainAccount(_ workspace: String) -> String { "\(workspace).user" }

    public static func token(_ name: String, _ w: Workspace) throws -> String {
        if let t = w.token {
            if w.isSlack { throw ConfigError.inlineTokenForSlack(name) }
            return t
        }
        let account = keychainAccount(name)
        guard let t = Keychain.read(service: Brand.keychainService, account: account) else {
            throw ConfigError.noToken(workspace: name, account: account)
        }
        return t
    }

    public static func appTokenAccount(_ workspace: String) -> String { "\(workspace).app" }

    /// The Socket Mode token: keychain `<ws>.app`, or for emulators only the
    /// config's `appToken`. nil means live updates fall back to polling.
    public static func appToken(_ name: String, _ w: Workspace) -> String? {
        if !w.isSlack, let t = w.appToken { return t }
        if w.isSlack, w.appToken != nil { log("config: \(name) has an inline appToken; ignored, real tokens live in the keychain") }
        return Keychain.read(service: Brand.keychainService, account: appTokenAccount(name))
    }
}

/// Reads go through /usr/bin/security so a rebuilt, re-signed binary isn't
/// met with an access prompt. Secrets come back on stdout and never reach argv.
public enum Keychain {
    public static func read(service: String, account: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
