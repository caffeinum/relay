import Foundation

public struct Person: Equatable {
    public var id: String; public var handle: String; public var displayName: String; public var realName: String
    public var isBot: Bool; public var botID: String?; public var deleted: Bool
    public var image48: String?; public var title: String?; public var tz: String?

    public init(id: String, handle: String, displayName: String = "", realName: String = "", isBot: Bool = false, botID: String? = nil,
                deleted: Bool = false, image48: String? = nil, title: String? = nil, tz: String? = nil) {
        self.id = id; self.handle = handle; self.displayName = displayName; self.realName = realName; self.isBot = isBot
        self.botID = botID; self.deleted = deleted; self.image48 = image48; self.title = title; self.tz = tz
    }

    /// Display name, then real name, then handle, as Slack shows people.
    public var label: String { [displayName, realName].first { !$0.isEmpty } ?? handle }
}

public struct Bot: Equatable {
    public var id: String; public var name: String; public var userID: String?; public var image48: String?
    public init(id: String, name: String, userID: String? = nil, image48: String? = nil) {
        self.id = id; self.name = name; self.userID = userID; self.image48 = image48
    }
}

public struct UserGroup: Equatable {
    public var id: String; public var handle: String; public var name: String; public var users: [String]
    public init(id: String, handle: String, name: String, users: [String]) { self.id = id; self.handle = handle; self.name = name; self.users = users }
}

/// In-memory copies of the small tables every frame reads. Loaded on first
/// use, dropped when the table is written. Loads run outside `lock`
/// because callers may already hold the database lock.
final class Directory {
    private let lock = NSLock()
    private var people: [String: Person]?
    private var bots: [String: Bot]?
    private var groups: Set<String>?

    func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func people(load: () throws -> [Person]) rethrows -> [String: Person] {
        if let p = withLock({ people }) { return p }
        let loaded = Dictionary(try load().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        withLock { people = loaded }
        return loaded
    }

    func bots(load: () throws -> [Bot]) rethrows -> [String: Bot] {
        if let b = withLock({ bots }) { return b }
        let loaded = Dictionary(try load().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        withLock { bots = loaded }
        return loaded
    }

    func groups(load: () throws -> Set<String>) rethrows -> Set<String> {
        if let g = withLock({ groups }) { return g }
        let loaded = try load()
        withLock { groups = loaded }
        return loaded
    }

    func invalidatePeople() { withLock { people = nil; groups = nil } }
    func invalidateBots() { withLock { bots = nil } }
    func invalidateGroups() { withLock { groups = nil } }
}

extension Store {
    // MARK: people

    public func put(users: [SlackUser]) throws {
        try db.transaction {
            for u in users {
                func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
                try db.run("""
                    INSERT INTO users(id,name,real_name,display_name,is_bot,deleted,image_48,title,tz,bot_id) VALUES(?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET name=excluded.name, real_name=excluded.real_name,
                      display_name=excluded.display_name, is_bot=excluded.is_bot, deleted=excluded.deleted,
                      image_48=excluded.image_48, title=excluded.title, tz=excluded.tz, bot_id=excluded.bot_id
                    """, u.id, u.name, [u.profile?.real_name, u.real_name].compactMap { $0 }.first { !$0.isEmpty } ?? "",
                           u.profile?.display_name ?? "", u.is_bot ?? false, u.deleted ?? false,
                           nonEmpty(u.profile?.image_48), nonEmpty(u.profile?.title), nonEmpty(u.tz), nonEmpty(u.profile?.bot_id))
            }
        }
        directory.invalidatePeople()
    }

    private func loadPeople() throws -> [Person] {
        try db.query("SELECT id, name, display_name, real_name, is_bot, bot_id, deleted, image_48, title, tz FROM users") { r in
            Person(id: r.text(0), handle: r.text(1), displayName: r.text(2), realName: r.text(3), isBot: r.bool(4), botID: r.string(5),
                   deleted: r.bool(6), image48: r.string(7), title: r.string(8), tz: r.string(9))
        }
    }

    private func peopleMap() -> [String: Person] {
        do { return try directory.people(load: loadPeople) } catch {
            log("people: \(error)")
            return [:]
        }
    }

    /// Everyone not deleted, by handle.
    public func people() throws -> [Person] {
        try directory.people(load: loadPeople).values.filter { !$0.deleted }.sorted { $0.handle < $1.handle }
    }

    /// Memory only after the first load: a miss does no I/O.
    public func person(_ id: String) -> Person? { peopleMap()[id] }

    /// The person's label, else a bot's name, else the raw id (A3).
    public func name(of user: String) -> String {
        if let p = person(user) { return p.label }
        if let b = bot(user) { return b.name }
        return user
    }

    // MARK: bots

    public func put(bots: [SlackBot]) throws {
        try db.transaction {
            for b in bots {
                try db.run("""
                    INSERT INTO bots(id,name,user_id,image_48,updated) VALUES(?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET name=excluded.name, user_id=coalesce(excluded.user_id, bots.user_id),
                      image_48=coalesce(excluded.image_48, bots.image_48), updated=excluded.updated
                    """, b.id, b.name, b.user_id, b.icons?.image_48.flatMap { $0.isEmpty ? nil : $0 }, Date().timeIntervalSince1970)
            }
        }
        directory.invalidateBots()
    }

    public func bot(_ id: String) -> Bot? {
        do {
            return try directory.bots {
                try db.query("SELECT id, name, user_id, image_48 FROM bots") { Bot(id: $0.text(0), name: $0.text(1), userID: $0.string(2), image48: $0.string(3)) }
            }[id]
        } catch {
            log("bots: \(error)")
            return nil
        }
    }

    // MARK: user groups

    public func put(usergroups: [SlackUserGroup], replacing: Bool = false) throws {
        try db.transaction {
            if replacing { try db.run("DELETE FROM usergroups") }
            for g in usergroups {
                if (g.date_delete ?? 0) > 0 { try db.run("DELETE FROM usergroups WHERE id=?", g.id); continue }
                try db.run("""
                    INSERT INTO usergroups(id,handle,name,users,updated) VALUES(?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET handle=excluded.handle, name=excluded.name, users=excluded.users, updated=excluded.updated
                    """, g.id, g.handle, g.name, String(decoding: try JSONEncoder().encode(g.users ?? []), as: UTF8.self), Date().timeIntervalSince1970)
            }
        }
        directory.invalidateGroups()
    }

    /// Empty when usergroups.list isn't available (kv "usergroups.unavailable" says why).
    public func usergroups() throws -> [UserGroup] {
        try db.query("SELECT id, handle, name, users FROM usergroups ORDER BY handle") { r in
            UserGroup(id: r.text(0), handle: r.text(1), name: r.text(2), users: try JSONDecoder().decode([String].self, from: Data(r.text(3).utf8)))
        }
    }

    /// The ids of the groups I'm in.
    public func myGroups() -> Set<String> {
        guard let me else { return [] }
        do {
            return try directory.groups { Set(try usergroups().filter { $0.users.contains(me) }.map(\.id)) }
        } catch {
            log("usergroups: \(error)")
            return []
        }
    }

    // MARK: members

    public func put(members: [String], channel: String) throws {
        try db.transaction {
            try db.run("DELETE FROM members WHERE channel=?", channel)
            for u in members { try db.run("INSERT OR IGNORE INTO members(channel,user) VALUES(?,?)", channel, u) }
            try setValue("members.\(channel)", String(Date().timeIntervalSince1970))
        }
    }

    public func addMember(_ user: String, channel: String) throws {
        try db.run("INSERT OR IGNORE INTO members(channel,user) VALUES(?,?)", channel, user)
    }

    public func members(_ channel: String) throws -> Set<String> {
        Set(try db.query("SELECT user FROM members WHERE channel=?", channel) { $0.text(0) })
    }

    /// When the member list was last fetched.
    public func membersFetched(_ channel: String) throws -> Date? {
        try value("members.\(channel)").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    // MARK: custom emoji

    public func put(emoji: [String: String], replacing: Bool) throws {
        try db.transaction {
            if replacing { try db.run("DELETE FROM emoji") }
            for (k, v) in emoji { try db.run("INSERT INTO emoji(name,value) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value", k, v) }
        }
    }

    public func removeEmoji(_ names: [String]) throws {
        try db.transaction { for n in names { try db.run("DELETE FROM emoji WHERE name=?", n) } }
    }

    /// name → url or "alias:x". Empty when emoji.list isn't available (kv "emoji.unavailable").
    public func customEmoji() throws -> [String: String] {
        Dictionary(try db.query("SELECT name, value FROM emoji") { ($0.text(0), $0.text(1)) }, uniquingKeysWith: { a, _ in a })
    }
}
