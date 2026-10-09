import Foundation

/// The app's name lives here and nowhere else: bundle id, support folder,
/// config folder, keychain service and env prefix all follow it, and
/// build.sh reads `name` out of this file.
public enum Brand {
    public static let name = "Relay"
    public static let slug = name.lowercased()
    public static let bundleID = "com.caffeinum.\(slug)"
    public static let keychainService = slug
    public static let cli = "\(slug)ctl"

    /// RELAY_HOME, RELAY_BENCH, RELAY_SCRIPT…
    public static func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment["\(slug.uppercased())_\(key)"]
    }
}

public enum Paths {
    public static var support: URL {
        if let o = Brand.env("HOME") { return URL(fileURLWithPath: o) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Brand.bundleID)
    }

    public static var config: URL {
        if let o = Brand.env("CONFIG") { return URL(fileURLWithPath: o) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\(Brand.slug)/config.json")
    }

    public static func database(_ workspace: String) -> URL { support.appendingPathComponent("\(workspace).sqlite") }
    public static var log: URL { support.appendingPathComponent("\(Brand.slug).log") }

    public static func ensure() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
}

public func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    guard let h = try? FileHandle(forWritingTo: Paths.log) else {
        try? line.write(to: Paths.log, atomically: false, encoding: .utf8)
        return
    }
    h.seekToEndOfFile()
    h.write(Data(line.utf8))
    try? h.close()
}
