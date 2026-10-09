import Foundation

public struct Draft: Equatable {
    public var channel: String; public var threadTS: String?
    /// Display text with mention tokens encoded (Mentions.encode output).
    public var text: String
    public var selection: NSRange; public var updated: Date

    public init(channel: String, threadTS: String?, text: String, selection: NSRange, updated: Date = Date()) {
        self.channel = channel; self.threadTS = threadTS; self.text = text; self.selection = selection; self.updated = updated
    }
}

public struct UIKey<T: Codable> {
    public let name: String
    public init(_ name: String) { self.name = name }
}

public struct ThreadRef: Codable, Equatable {
    public var channel: String; public var ts: String
    public init(channel: String, ts: String) { self.channel = channel; self.ts = ts }
}

public struct ScrollAnchor: Codable, Equatable {
    public var ts: String; public var offset: Double
    public init(ts: String, offset: Double) { self.ts = ts; self.offset = offset }
}

public struct SectionState: Codable, Equatable {
    public enum Sort: String, Codable { case alpha, recent }
    public var id: String; public var name: String; public var icon: String?
    public var channels: [String]; public var collapsed: Bool; public var sort: Sort
    public init(id: String, name: String, icon: String? = nil, channels: [String], collapsed: Bool = false, sort: Sort = .alpha) {
        self.id = id; self.name = name; self.icon = icon; self.channels = channels; self.collapsed = collapsed; self.sort = sort
    }
}

// Every UI key lives under "ui:" in kv, apart from the raw "ui.current"
// that the pre-SHELL MainController still writes with `set`.
extension UIKey where T == String {
    public static let current = UIKey<String>("ui:current")
    public static func threadRead(_ channel: String, _ ts: String) -> UIKey<String> { .init("ui:threadRead:\(channel)/\(ts)") }
}
extension UIKey where T == ThreadRef { public static let openThread = UIKey<ThreadRef>("ui:openThread") }
extension UIKey where T == [SectionState] { public static let sections = UIKey<[SectionState]>("ui:sections") }
extension UIKey where T == [String] {
    public static let starred = UIKey<[String]>("ui:starred")
    public static let recents = UIKey<[String]>("ui:recents")
    /// "C/ts"
    public static let saved = UIKey<[String]>("ui:saved")
}
extension UIKey where T == Bool { public static let sidebarVisible = UIKey<Bool>("ui:sidebarVisible") }
extension UIKey where T == Double {
    public static let sidebarWidth = UIKey<Double>("ui:sidebarWidth")
    public static let threadWidth = UIKey<Double>("ui:threadWidth")
}
extension UIKey where T == [String: Int] { public static let frequentEmoji = UIKey<[String: Int]>("ui:frequentEmoji") }
extension UIKey where T == ScrollAnchor {
    public static func scroll(_ channel: String) -> UIKey<ScrollAnchor> { .init("ui:scroll:\(channel)") }
}

public enum LocalStateError: Error, CustomStringConvertible {
    case decode(key: String, Error)
    public var description: String {
        switch self { case .decode(let k, let e): return "kv \(k) doesn't decode: \(e)" }
    }
}

extension Store {
    // MARK: UI state

    /// A value that is there but doesn't decode throws; it never reads as nil.
    public func ui<T>(_ k: UIKey<T>) throws -> T? {
        guard let raw = try value(k.name) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: Data(raw.utf8)) } catch { throw LocalStateError.decode(key: k.name, error) }
    }

    /// nil deletes.
    public func setUI<T>(_ k: UIKey<T>, _ v: T?) throws {
        try setValue(k.name, try v.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) })
    }

    // MARK: drafts

    public func draft(_ channel: String, thread: String?) throws -> Draft? {
        try db.query("SELECT text, sel_loc, sel_len, updated FROM drafts WHERE channel=? AND thread_ts=?", channel, thread ?? "") { r in
            Draft(channel: channel, threadTS: thread, text: r.text(0), selection: NSRange(location: r.int(1), length: r.int(2)),
                  updated: Date(timeIntervalSince1970: r.double(3)))
        }.first
    }

    /// Empty or whitespace-only text deletes the draft.
    public func saveDraft(_ d: Draft) throws {
        guard !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try clearDraft(d.channel, thread: d.threadTS)
            return
        }
        try db.run("""
            INSERT INTO drafts(channel,thread_ts,text,sel_loc,sel_len,updated) VALUES(?,?,?,?,?,?)
            ON CONFLICT(channel,thread_ts) DO UPDATE SET text=excluded.text, sel_loc=excluded.sel_loc,
              sel_len=excluded.sel_len, updated=excluded.updated
            """, d.channel, d.threadTS ?? "", d.text, d.selection.location, d.selection.length, d.updated.timeIntervalSince1970)
    }

    public func clearDraft(_ channel: String, thread: String?) throws {
        try db.run("DELETE FROM drafts WHERE channel=? AND thread_ts=?", channel, thread ?? "")
    }

    /// Newest first.
    public func drafts() throws -> [Draft] {
        try db.query("SELECT channel, thread_ts, text, sel_loc, sel_len, updated FROM drafts ORDER BY updated DESC") { r in
            Draft(channel: r.text(0), threadTS: r.text(1).isEmpty ? nil : r.text(1), text: r.text(2),
                  selection: NSRange(location: r.int(3), length: r.int(4)), updated: Date(timeIntervalSince1970: r.double(5)))
        }
    }

    /// Threads in `channel` that hold a draft.
    public func draftThreads(_ channel: String) throws -> Set<String> {
        Set(try db.query("SELECT thread_ts FROM drafts WHERE channel=? AND thread_ts != ''", channel) { $0.text(0) })
    }
}
