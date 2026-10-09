import Foundation

public struct Conversation: Equatable {
    public enum Kind: String { case channel, `private`, im, mpim }
    public var id: String
    public var name: String
    public var kind: Kind
    public var userID: String?
    public var lastRead: String
    public var latest: String
    public var unread: Int
    public var mentions: Int

    public var isDM: Bool { kind == .im || kind == .mpim }
    public var label: String { kind == .channel || kind == .private ? "#\(name)" : name }
}

public struct Message: Equatable {
    public var id: Int64
    public var channel: String
    public var ts: String
    public var threadTS: String?
    public var user: String
    public var author: String
    public var text: String
    public var subtype: String?
    public var replyCount: Int
    public var latestReply: String?
    public var edited: Bool
    public var reactions: [SlackReaction]

    public var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }
    public var isThreadReply: Bool { threadTS != nil && threadTS != ts }
}

public struct Hit: Equatable {
    public var channel: String
    public var channelName: String
    public var ts: String
    public var author: String
    public var text: String
    public var remote: Bool
}

/// The on-disk cache for one workspace: conversations, people, every
/// message seen, and an fts5 index over message text. The first frame is a
/// handful of indexed reads from here.
public final class Store {
    public let db: Database
    public static let schemaVersion = 1

    public init(path: String) throws {
        db = try Database(path: path)
        try migrate()
    }

    private func migrate() throws {
        guard try db.scalar("PRAGMA user_version") < Self.schemaVersion else { return }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS users(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, real_name TEXT NOT NULL, display_name TEXT NOT NULL,
            is_bot INTEGER NOT NULL, deleted INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS convs(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, user_id TEXT,
            last_read TEXT NOT NULL DEFAULT '0', seen TEXT NOT NULL DEFAULT '0', latest TEXT NOT NULL DEFAULT '0',
            synced TEXT, oldest TEXT, complete INTEGER NOT NULL DEFAULT 0, present INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE IF NOT EXISTS messages(
            id INTEGER PRIMARY KEY, channel TEXT NOT NULL, ts TEXT NOT NULL, thread_ts TEXT, user TEXT NOT NULL,
            text TEXT NOT NULL, subtype TEXT, reply_count INTEGER NOT NULL DEFAULT 0, latest_reply TEXT,
            edited INTEGER NOT NULL DEFAULT 0, reactions TEXT, UNIQUE(channel, ts));
        CREATE INDEX IF NOT EXISTS messages_thread ON messages(channel, thread_ts, ts);
        CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS msg_fts USING fts5(text, tokenize = 'unicode61 remove_diacritics 2');
        PRAGMA user_version = \(Self.schemaVersion);
        """)
    }

    // MARK: kv

    public func get(_ key: String) -> String? { try? db.string("SELECT value FROM kv WHERE key=?", key) }
    public func set(_ key: String, _ value: String) {
        try? db.run("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, value)
    }

    public var me: String? { self.get("me") }

    // MARK: users

    public func put(users: [SlackUser]) throws {
        try db.transaction {
            for u in users {
                try db.run("""
                    INSERT INTO users(id,name,real_name,display_name,is_bot,deleted) VALUES(?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET name=excluded.name, real_name=excluded.real_name,
                      display_name=excluded.display_name, is_bot=excluded.is_bot, deleted=excluded.deleted
                    """, u.id, u.name, [u.profile?.real_name, u.real_name].compactMap { $0 }.first { !$0.isEmpty } ?? "", u.profile?.display_name ?? "",
                           u.is_bot ?? false, u.deleted ?? false)
            }
        }
        namesLock.lock()
        names = nil
        namesLock.unlock()
    }

    private var names: [String: String]?
    private let namesLock = NSLock()

    /// Display name, then real name, then handle — as Slack shows people.
    public func name(of user: String) -> String {
        namesLock.lock()
        let cached = names
        namesLock.unlock()
        if let cached { return cached[user] ?? user }
        // Read outside namesLock: callers may already hold the db lock.
        let loaded = Dictionary(uniqueKeysWithValues: (try? db.query("SELECT id, display_name, real_name, name FROM users") { r in
            (r.text(0), [r.text(1), r.text(2), r.text(3)].first { !$0.isEmpty } ?? r.text(0))
        }) ?? [])
        namesLock.lock()
        names = loaded
        namesLock.unlock()
        return loaded[user] ?? user
    }

    // MARK: conversations

    /// Replaces the conversation list. Ones that vanished stay cached but
    /// stop showing, so their messages still search.
    public func put(conversations: [SlackConversation], me: String) throws {
        try db.transaction {
            try db.run("UPDATE convs SET present=0")
            for c in conversations {
                let name: String
                switch c.kind {
                case "im":
                    guard let u = c.user else { throw SlackError.api(method: "conversations.list", error: "im \(c.id) has no user", needed: nil) }
                    name = u
                default:
                    guard let n = c.name else { throw SlackError.api(method: "conversations.list", error: "\(c.id) has no name", needed: nil) }
                    name = n
                }
                try db.run("""
                    INSERT INTO convs(id,name,kind,user_id,present) VALUES(?,?,?,?,1)
                    ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind, user_id=excluded.user_id, present=1
                    """, c.id, name, c.kind, c.user)
                if let lr = c.last_read { try db.run("UPDATE convs SET last_read=? WHERE id=?", lr, c.id) }
            }
        }
    }

    public func setLastRead(_ channel: String, _ ts: String) throws {
        try db.run("UPDATE convs SET last_read=? WHERE id=?", ts, channel)
    }

    /// Read here but not marked on Slack (writes are off): counts as read
    /// locally until Slack's own cursor passes it.
    public func markSeen(_ channel: String, _ ts: String) throws {
        try db.run("UPDATE convs SET seen=max(seen, ?) WHERE id=?", ts, channel)
    }

    public func syncState(_ channel: String) -> (synced: String?, oldest: String?, complete: Bool) {
        (try? db.query("SELECT synced, oldest, complete FROM convs WHERE id=?", channel) { ($0.string(0), $0.string(1), $0.bool(2)) }.first) ?? (nil, nil, false)
    }

    public func conversations() throws -> [Conversation] {
        let me = self.me ?? ""
        return try db.query("""
            WITH c AS (SELECT *, max(last_read, seen) AS read FROM convs WHERE present=1)
            SELECT c.id, c.name, c.kind, c.user_id, c.read, c.latest,
              (SELECT count(*) FROM messages m WHERE m.channel=c.id AND m.ts > c.read AND m.user != ?
                 AND (m.thread_ts IS NULL OR m.thread_ts = m.ts) AND coalesce(m.subtype,'') NOT IN ('channel_join','channel_leave')),
              (SELECT count(*) FROM messages m WHERE m.channel=c.id AND m.ts > c.read AND m.text LIKE ?)
            FROM c
            """, me, "%<@\(me)>%") { r in
            let kind = Conversation.Kind(rawValue: r.text(2)) ?? .channel
            var c = Conversation(id: r.text(0), name: r.text(1), kind: kind, userID: r.string(3), lastRead: r.text(4),
                                 latest: r.text(5), unread: r.int(6), mentions: r.int(7))
            if kind == .im, let u = c.userID { c.name = name(of: u) }
            return c
        }
    }

    // MARK: messages

    /// Writes messages (top-level or replies) and keeps fts and each
    /// conversation's newest ts in step.
    public func put(messages: [SlackMessage], channel: String) throws {
        guard !messages.isEmpty else { return }
        let enc = JSONEncoder()
        try db.transaction {
            for m in messages {
                let reactions = try m.reactions.map { String(decoding: try enc.encode($0), as: UTF8.self) }
                try db.run("""
                    INSERT INTO messages(channel,ts,thread_ts,user,text,subtype,reply_count,latest_reply,edited,reactions)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(channel,ts) DO UPDATE SET thread_ts=excluded.thread_ts, user=excluded.user, text=excluded.text,
                      subtype=excluded.subtype, reply_count=max(messages.reply_count, excluded.reply_count),
                      latest_reply=coalesce(excluded.latest_reply, messages.latest_reply), edited=excluded.edited, reactions=excluded.reactions
                    """, channel, m.ts, m.thread_ts, m.user ?? m.bot_id ?? m.username ?? "", m.text ?? "", m.subtype,
                           m.reply_count ?? 0, m.latest_reply, m.edited != nil, reactions)
                let id = try db.query("SELECT id FROM messages WHERE channel=? AND ts=?", channel, m.ts) { $0.int64(0) }[0]
                try db.run("DELETE FROM msg_fts WHERE rowid=?", id)
                try db.run("INSERT INTO msg_fts(rowid, text) VALUES(?,?)", id, Mrkdwn.plain(m.text ?? "", names: name(of:)))
            }
            let top = messages.filter { $0.thread_ts == nil || $0.thread_ts == $0.ts }.map(\.ts).max()
            if let top { try db.run("UPDATE convs SET latest=max(latest, ?) WHERE id=?", top, channel) }
        }
    }

    public func delete(channel: String, ts: String) throws {
        try db.transaction {
            for id in try db.query("SELECT id FROM messages WHERE channel=? AND ts=?", channel, ts, map: { $0.int64(0) }) {
                try db.run("DELETE FROM msg_fts WHERE rowid=?", id)
                try db.run("DELETE FROM messages WHERE id=?", id)
            }
        }
    }

    /// Records how far history has been fetched in each direction.
    public func markSynced(_ channel: String, newest: String?, oldest: String?, complete: Bool?) throws {
        if let newest { try db.run("UPDATE convs SET synced=max(coalesce(synced,'0'), ?) WHERE id=?", newest, channel) }
        if let oldest { try db.run("UPDATE convs SET oldest=CASE WHEN oldest IS NULL OR ? < oldest THEN ? ELSE oldest END WHERE id=?", oldest, oldest, channel) }
        if let complete { try db.run("UPDATE convs SET complete=? WHERE id=?", complete, channel) }
    }

    private static let messageColumns = "id, channel, ts, thread_ts, user, text, subtype, reply_count, latest_reply, edited, reactions"

    private func message(_ r: Row) -> Message {
        let reactions = r.string(10).flatMap { try? JSONDecoder().decode([SlackReaction].self, from: Data($0.utf8)) } ?? []
        return Message(id: r.int64(0), channel: r.text(1), ts: r.text(2), threadTS: r.string(3), user: r.text(4),
                       author: name(of: r.text(4)), text: r.text(5), subtype: r.string(6), replyCount: r.int(7),
                       latestReply: r.string(8), edited: r.bool(9), reactions: reactions)
    }

    /// The newest `limit` top-level messages, oldest first for drawing.
    public func messages(_ channel: String, limit: Int = 200) throws -> [Message] {
        try db.query("""
            SELECT \(Self.messageColumns) FROM messages
            WHERE channel=? AND (thread_ts IS NULL OR thread_ts = ts) ORDER BY ts DESC LIMIT ?
            """, channel, limit, map: message).reversed()
    }

    public func thread(_ channel: String, ts: String) throws -> [Message] {
        try db.query("""
            SELECT \(Self.messageColumns) FROM messages WHERE channel=? AND (ts=? OR thread_ts=?) ORDER BY ts
            """, channel, ts, ts, map: message)
    }

    /// Local search: fts5 prefix match on every word, newest first.
    public func search(_ query: String, limit: Int = 100) throws -> [Hit] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { w in
            "\"" + w.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        }
        guard !words.isEmpty else { return [] }
        let convs = Dictionary(uniqueKeysWithValues: try conversations().map { ($0.id, $0.label) })
        return try db.query("""
            SELECT m.channel, m.ts, m.user, m.text FROM msg_fts f JOIN messages m ON m.id = f.rowid
            WHERE msg_fts MATCH ? ORDER BY m.ts DESC LIMIT ?
            """, words.joined(separator: " "), limit) { r in
            Hit(channel: r.text(0), channelName: convs[r.text(0)] ?? r.text(0), ts: r.text(1), author: name(of: r.text(2)),
                text: r.text(3), remote: false)
        }
    }

    public var messageCount: Int { (try? db.scalar("SELECT count(*) FROM messages")) ?? 0 }
}
