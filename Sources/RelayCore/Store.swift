import Foundation

public struct Conversation: Equatable {
    public enum Kind: String { case channel, `private`, im, mpim }
    public var id: String
    /// mpim: the other members' names joined ", ".
    public var name: String
    public var kind: Kind
    public var userID: String?
    /// max(last_read, seen)
    public var lastRead: String
    public var latest: String
    public var unread: Int
    /// DMs: every unread counts.
    public var mentions: Int
    public var topic: String?
    public var isSelf: Bool
    public var userIsBot: Bool
    /// A channel draft or any thread draft.
    public var hasDraft: Bool

    public init(id: String, name: String, kind: Kind, userID: String? = nil, lastRead: String = "0", latest: String = "0",
                unread: Int = 0, mentions: Int = 0, topic: String? = nil, isSelf: Bool = false, userIsBot: Bool = false, hasDraft: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.userID = userID; self.lastRead = lastRead; self.latest = latest
        self.unread = unread; self.mentions = mentions; self.topic = topic; self.isSelf = isSelf; self.userIsBot = userIsBot; self.hasDraft = hasDraft
    }

    public var isDM: Bool { kind == .im || kind == .mpim }
    public var label: String { kind == .channel || kind == .private ? "#\(name)" : name }
}

public struct Unfurl: Equatable {
    public var title: String?; public var text: String?; public var serviceName: String?
    public var url: String?; public var color: String?; public var thumb: String?

    public init(title: String? = nil, text: String? = nil, serviceName: String? = nil, url: String? = nil, color: String? = nil, thumb: String? = nil) {
        self.title = title; self.text = text; self.serviceName = serviceName; self.url = url; self.color = color; self.thumb = thumb
    }

    init(_ a: SlackMessage.Attachment) {
        self.init(title: a.title, text: a.text ?? a.fallback, serviceName: a.service_name,
                  url: a.title_link ?? a.from_url ?? a.original_url, color: a.color, thumb: a.thumb_url ?? a.image_url)
    }
}

public struct Message: Equatable {
    /// Local echo: -outbox.id
    public var id: Int64
    public var channel: String
    /// Local echo of a send: outbox.local_ts
    public var ts: String
    public var threadTS: String?
    /// "" only when Slack sent neither user nor bot_id (logged).
    public var user: String
    /// The user's name, else the bot's, else the message's username.
    public var author: String
    /// mrkdwn source; for an edit echo, the new text.
    public var text: String
    public var subtype: String?
    public var replyCount: Int
    public var latestReply: String?
    public var reactions: [SlackReaction]
    public var editedTS: String?
    public var botID: String?
    public var isBot: Bool
    /// image_48 URL, the user's or the bot's.
    public var avatar: String?
    public var isMine: Bool
    /// <@me>, one of my usergroups, or here/channel/everyone.
    public var mentionsMe: Bool
    /// Up to 3, for the thread summary.
    public var replyUsers: [String]
    public var unfurls: [Unfurl]
    /// nil: a server message.
    public var local: LocalEcho?

    public init(id: Int64, channel: String, ts: String, threadTS: String? = nil, user: String, author: String, text: String,
                subtype: String? = nil, replyCount: Int = 0, latestReply: String? = nil, reactions: [SlackReaction] = [],
                editedTS: String? = nil, botID: String? = nil, isBot: Bool = false, avatar: String? = nil, isMine: Bool = false,
                mentionsMe: Bool = false, replyUsers: [String] = [], unfurls: [Unfurl] = [], local: LocalEcho? = nil) {
        self.id = id; self.channel = channel; self.ts = ts; self.threadTS = threadTS; self.user = user; self.author = author
        self.text = text; self.subtype = subtype; self.replyCount = replyCount; self.latestReply = latestReply
        self.reactions = reactions; self.editedTS = editedTS; self.botID = botID; self.isBot = isBot; self.avatar = avatar
        self.isMine = isMine; self.mentionsMe = mentionsMe; self.replyUsers = replyUsers; self.unfurls = unfurls; self.local = local
    }

    public static let systemSubtypes: Set<String> = ["channel_join", "channel_leave", "channel_topic", "channel_purpose"]

    public var edited: Bool { editedTS != nil }
    public var isSystem: Bool { subtype.map(Self.systemSubtypes.contains) ?? false }
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

/// A Slack-style ts for now, ordered the same way as server ts strings.
public func slackTS(_ d: Date = Date()) -> String { String(format: "%.6f", d.timeIntervalSince1970) }

/// The on-disk cache for one workspace: conversations, people, every
/// message seen, and an fts5 index over message text. The first frame is a
/// handful of indexed reads from here.
public final class Store {
    public let db: Database
    public static let schemaVersion = 2
    let directory = Directory()

    public init(path: String) throws {
        db = try Database(path: path)
        try migrate()
    }

    private func migrate() throws {
        let v = try db.scalar("PRAGMA user_version")
        if v < 1 {
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
            PRAGMA user_version = 1;
            """)
        }
        if v < 2 {
            // v1 kept `user = user ?? bot_id`, and only a flag for edits: the
            // edit time of those rows is unknown, so their ts stands in.
            try db.transaction {
                try db.exec("""
                ALTER TABLE messages ADD COLUMN bot_id TEXT;
                ALTER TABLE messages ADD COLUMN username TEXT;
                ALTER TABLE messages ADD COLUMN edited_ts TEXT;
                ALTER TABLE messages ADD COLUMN attachments TEXT;
                ALTER TABLE messages ADD COLUMN reply_users TEXT;
                UPDATE messages SET edited_ts = ts WHERE edited = 1;
                UPDATE messages SET bot_id = user WHERE user LIKE 'B%';
                ALTER TABLE users ADD COLUMN image_48 TEXT;
                ALTER TABLE users ADD COLUMN title TEXT;
                ALTER TABLE users ADD COLUMN tz TEXT;
                ALTER TABLE users ADD COLUMN bot_id TEXT;
                CREATE TABLE conv_meta(id TEXT PRIMARY KEY, topic TEXT, member_count INTEGER, is_member INTEGER, user_is_bot INTEGER);
                CREATE TABLE members(channel TEXT NOT NULL, user TEXT NOT NULL, PRIMARY KEY(channel, user));
                CREATE TABLE bots(id TEXT PRIMARY KEY, name TEXT NOT NULL, user_id TEXT, image_48 TEXT, updated REAL NOT NULL);
                CREATE TABLE usergroups(id TEXT PRIMARY KEY, handle TEXT NOT NULL, name TEXT NOT NULL, users TEXT NOT NULL, updated REAL NOT NULL);
                CREATE TABLE emoji(name TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE drafts(channel TEXT NOT NULL, thread_ts TEXT NOT NULL DEFAULT '', text TEXT NOT NULL,
                    sel_loc INTEGER NOT NULL, sel_len INTEGER NOT NULL, updated REAL NOT NULL, PRIMARY KEY(channel, thread_ts));
                CREATE TABLE outbox(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, state TEXT NOT NULL, channel TEXT NOT NULL,
                    thread_ts TEXT, target_ts TEXT, local_ts TEXT NOT NULL, text TEXT, original TEXT, error TEXT,
                    created REAL NOT NULL, sends_at REAL NOT NULL, sent_ts TEXT);
                CREATE TABLE events(id TEXT PRIMARY KEY, at REAL NOT NULL);
                CREATE INDEX messages_top ON messages(channel, ts, user, subtype) WHERE thread_ts IS NULL OR thread_ts = ts;
                CREATE INDEX outbox_live ON outbox(channel, state);
                PRAGMA user_version = 2;
                """)
            }
        }
    }

    // MARK: kv

    public func value(_ key: String) throws -> String? { try db.string("SELECT value FROM kv WHERE key=?", key) }

    /// nil deletes.
    public func setValue(_ key: String, _ value: String?) throws {
        guard let value else { try db.run("DELETE FROM kv WHERE key=?", key); return }
        try db.run("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, value)
    }

    public func get(_ key: String) -> String? {
        do { return try value(key) } catch { log("kv get \(key): \(error)"); return nil }
    }

    /// Compatibility until SHELL moves to `setUI`: failures are logged.
    public func set(_ key: String, _ value: String) {
        do { try setValue(key, value) } catch { log("kv set \(key): \(error)") }
    }

    public var me: String? { self.get("me") }

    // MARK: conversations

    /// Replaces the conversation list. Ones that vanished stay cached but
    /// stop showing, so their messages still search.
    public func put(conversations: [SlackConversation], me: String) throws {
        try db.transaction {
            try db.run("UPDATE convs SET present=0")
            for c in conversations { try upsert(c) }
        }
    }

    /// One conversation, without touching the others (conversations.open).
    public func upsert(conversation c: SlackConversation) throws {
        try db.transaction { try upsert(c) }
    }

    private func upsert(_ c: SlackConversation) throws {
        let name: String
        switch c.kind {
        case "im":
            guard let u = c.user else { throw SlackError.api(method: "conversations", error: "im \(c.id) has no user", needed: nil) }
            name = u
        default:
            guard let n = c.name else { throw SlackError.api(method: "conversations", error: "\(c.id) has no name", needed: nil) }
            name = n
        }
        try db.run("""
            INSERT INTO convs(id,name,kind,user_id,present) VALUES(?,?,?,?,1)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind, user_id=excluded.user_id, present=1
            """, c.id, name, c.kind, c.user)
        if let lr = c.last_read { try db.run("UPDATE convs SET last_read=? WHERE id=?", lr, c.id) }
        try db.run("""
            INSERT INTO conv_meta(id, topic, member_count, is_member, user_is_bot)
            VALUES(?, ?, ?, ?, (SELECT is_bot FROM users WHERE id=?))
            ON CONFLICT(id) DO UPDATE SET topic=coalesce(excluded.topic, conv_meta.topic),
              member_count=coalesce(excluded.member_count, conv_meta.member_count),
              is_member=coalesce(excluded.is_member, conv_meta.is_member), user_is_bot=excluded.user_is_bot
            """, c.id, c.topic?.value.flatMap { $0.isEmpty ? nil : $0 }, c.num_members, c.is_member, c.user)
    }

    public func setLastRead(_ channel: String, _ ts: String) throws {
        try db.run("UPDATE convs SET last_read=? WHERE id=?", ts, channel)
    }

    /// Read here but not marked on Slack (writes are off): counts as read
    /// locally until Slack's own cursor passes it.
    public func markSeen(_ channel: String, _ ts: String) throws {
        try db.run("UPDATE convs SET seen=max(seen, ?) WHERE id=?", ts, channel)
    }

    /// Moves both cursors back, so `ts` and everything after it is unread
    /// again. Returns the new cursor.
    @discardableResult
    public func markUnread(_ channel: String, from ts: String) throws -> String {
        let cursor = tsBefore(ts)
        try db.run("UPDATE convs SET seen=?, last_read=min(last_read, ?) WHERE id=?", cursor, cursor, channel)
        return cursor
    }

    /// Slack's cursor moved (conversations.mark went through): never backwards.
    public func advanceLastRead(_ channel: String, _ ts: String) throws {
        try db.run("UPDATE convs SET last_read=max(last_read, ?) WHERE id=?", ts, channel)
    }

    public func syncState(_ channel: String) -> (synced: String?, oldest: String?, complete: Bool) {
        do {
            return try db.query("SELECT synced, oldest, complete FROM convs WHERE id=?", channel) { ($0.string(0), $0.string(1), $0.bool(2)) }.first ?? (nil, nil, false)
        } catch {
            log("syncState \(channel): \(error)")
            return (nil, nil, false)
        }
    }

    /// The LIKE patterns that make a message a mention of me.
    func mentionPatterns(_ me: String) -> [String] {
        ["%<@\(me)>%", "%<@\(me)|%", "%<!here%", "%<!channel%", "%<!everyone%"] + myGroups().sorted().map { "%<!subteam^\($0)%" }
    }

    static let unreadSQL = """
        SELECT count(*) FROM messages m WHERE m.channel=c.id AND m.ts > c.read AND (m.thread_ts IS NULL OR m.thread_ts = m.ts)
          AND m.user != ? AND coalesce(m.subtype,'') NOT IN ('channel_join','channel_leave','channel_topic','channel_purpose')
        """

    static func mentionSQL(_ n: Int) -> String {
        "SELECT count(*) FROM messages m WHERE m.channel=c.id AND m.ts > c.read AND m.user != ? AND instr(m.text, '<') > 0 AND ("
            + Array(repeating: "m.text LIKE ?", count: n).joined(separator: " OR ") + ")"
    }

    public func conversations() throws -> [Conversation] { try conversations(where: "present=1", []) }

    public func conversation(_ id: String) throws -> Conversation? { try conversations(where: "id=?", [id]).first }

    private func conversations(where filter: String, _ args: [SQLBindable]) throws -> [Conversation] {
        let me = self.me ?? ""
        let patterns = mentionPatterns(me)
        let convs = try db.query("""
            WITH c AS (SELECT *, max(last_read, seen) AS read FROM convs WHERE \(filter))
            SELECT c.id, c.name, c.kind, c.user_id, c.read, c.latest, (\(Self.unreadSQL)), (\(Self.mentionSQL(patterns.count))),
              meta.topic, coalesce(u.is_bot, 0), EXISTS(SELECT 1 FROM drafts d WHERE d.channel=c.id)
            FROM c LEFT JOIN conv_meta meta ON meta.id=c.id LEFT JOIN users u ON u.id=c.user_id
            """, args + [me, me] + patterns) { r in
            let kind = Conversation.Kind(rawValue: r.text(2)) ?? .channel
            var c = Conversation(id: r.text(0), name: r.text(1), kind: kind, userID: r.string(3), lastRead: r.text(4),
                                 latest: r.text(5), unread: r.int(6), mentions: r.int(7), topic: r.string(8),
                                 isSelf: kind == .im && r.string(3) == me, userIsBot: r.bool(9), hasDraft: r.bool(10))
            if c.isDM { c.mentions = c.unread }
            if kind == .im, let u = c.userID { c.name = name(of: u) }
            return c
        }
        guard convs.contains(where: { $0.kind == .mpim }) else { return convs }
        let members = Dictionary(grouping: try db.query("""
            SELECT channel, user FROM members WHERE channel IN (SELECT id FROM convs WHERE kind='mpim') ORDER BY rowid
            """) { ($0.text(0), $0.text(1)) }, by: \.0)
        return convs.map { c in
            guard c.kind == .mpim else { return c }
            var c = c
            c.name = mpimName(c.name, members: members[c.id]?.map(\.1), me: me)
            return c
        }
    }

    /// The members' names when known, else the handles out of Slack's
    /// `mpdm-a--b--c-1` name, each resolved when the handle is known.
    func mpimName(_ raw: String, members: [String]?, me: String) -> String {
        if let members, !members.isEmpty { return members.filter { $0 != me }.map(name(of:)).joined(separator: ", ") }
        guard raw.hasPrefix("mpdm-") else { return raw }
        var body = raw.dropFirst(5)
        if let dash = body.lastIndex(of: "-"), body[body.index(after: dash)...].allSatisfy(\.isNumber) { body = body[..<dash] }
        let byHandle = Dictionary((try? people())?.map { ($0.handle, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        let mine = me.isEmpty ? nil : person(me)?.handle
        return body.components(separatedBy: "--").filter { $0 != mine }.map { byHandle[$0]?.label ?? $0 }.joined(separator: ", ")
    }

    // MARK: messages

    private var unattributed = Set<String>()
    private let unattributedLock = NSLock()

    private func noteUnattributed(_ channel: String, _ ts: String) {
        unattributedLock.lock()
        let first = unattributed.insert("\(channel)/\(ts)").inserted
        unattributedLock.unlock()
        if first { log("message \(channel)/\(ts) has no user or bot_id") }
    }

    /// Writes messages (top-level or replies) and keeps fts and each
    /// conversation's newest ts in step. A message of mine that matches a
    /// `sending` outbox row resolves it (the echo came before the reply), as
    /// does one left failed by a quit mid-send.
    public func put(messages: [SlackMessage], channel: String, resolvingEchoes: Bool = true) throws {
        guard !messages.isEmpty else { return }
        let enc = JSONEncoder()
        func json<T: Encodable>(_ v: T?) throws -> String? { try v.map { String(decoding: try enc.encode($0), as: UTF8.self) } }
        let me = self.me
        try db.transaction {
            for m in messages {
                if m.user == nil && m.bot_id == nil { noteUnattributed(channel, m.ts) }
                if let b = m.bot_profile, let name = b.name {
                    try db.run("""
                        INSERT INTO bots(id,name,image_48,updated) VALUES(?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET name=excluded.name, image_48=coalesce(excluded.image_48, bots.image_48)
                        """, b.id, name, b.icons?.image_48.flatMap { $0.isEmpty ? nil : $0 }, Date().timeIntervalSince1970)
                    directory.invalidateBots()
                }
                let user = m.user ?? m.bot_id ?? ""
                try db.run("""
                    INSERT INTO messages(channel,ts,thread_ts,user,text,subtype,reply_count,latest_reply,edited,reactions,
                      bot_id,username,edited_ts,attachments,reply_users)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(channel,ts) DO UPDATE SET thread_ts=excluded.thread_ts, user=excluded.user, text=excluded.text,
                      subtype=excluded.subtype, reply_count=max(messages.reply_count, excluded.reply_count),
                      latest_reply=coalesce(excluded.latest_reply, messages.latest_reply), edited=excluded.edited,
                      reactions=excluded.reactions, bot_id=excluded.bot_id, username=excluded.username,
                      edited_ts=excluded.edited_ts, attachments=excluded.attachments,
                      reply_users=coalesce(excluded.reply_users, messages.reply_users)
                    """, channel, m.ts, m.thread_ts, user, m.text ?? "", m.subtype, m.reply_count ?? 0, m.latest_reply,
                           m.edited != nil, try json(m.reactions), m.bot_id, m.username, m.edited?.ts,
                           try json(m.attachments.flatMap { $0.isEmpty ? nil : $0 }), try json(m.reply_users))
                let id = try db.query("SELECT id FROM messages WHERE channel=? AND ts=?", channel, m.ts) { $0.int64(0) }[0]
                try db.run("DELETE FROM msg_fts WHERE rowid=?", id)
                try db.run("INSERT INTO msg_fts(rowid, text) VALUES(?,?)", id, Mrkdwn.plain(m.text ?? "", names: name(of:)))
                if resolvingEchoes, let me, user == me { try resolveEcho(channel: channel, thread: m.thread_ts, text: m.text ?? "", ts: m.ts) }
            }
            let top = messages.filter { $0.thread_ts == nil || $0.thread_ts == $0.ts }.map(\.ts).max()
            if let top { try db.run("UPDATE convs SET latest=max(latest, ?) WHERE id=?", top, channel) }
        }
    }

    private func resolveEcho(channel: String, thread: String?, text: String, ts: String) throws {
        try db.run("""
            UPDATE outbox SET state='sent', sent_ts=? WHERE id=(SELECT min(id) FROM outbox
              WHERE channel=? AND kind='send' AND coalesce(thread_ts,'')=? AND text=?
                AND (state='sending' OR (state='failed' AND error=?)))
            """, ts, channel, thread ?? "", text, Outbox.quitError)
    }

    public func exists(channel: String, ts: String) throws -> Bool {
        try db.scalar("SELECT count(*) FROM messages WHERE channel=? AND ts=?", channel, ts) > 0
    }

    /// A live reply landed: bump its parent's summary.
    public func noteReply(channel: String, parent: String, ts: String, user: String) throws {
        try db.transaction {
            let current = try db.query("SELECT reply_users FROM messages WHERE channel=? AND ts=?", channel, parent) { $0.string(0) }
            guard let row = current.first else { return }
            var users = try row.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            if !user.isEmpty, !users.contains(user) { users.append(user) }
            try db.run("""
                UPDATE messages SET reply_count=reply_count+1, latest_reply=max(coalesce(latest_reply,'0'), ?), reply_users=?
                WHERE channel=? AND ts=?
                """, ts, String(decoding: try JSONEncoder().encode(users), as: UTF8.self), channel, parent)
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

    /// Our own edit succeeded: the new text now, Slack's copy on the next sync.
    public func applyEdit(channel: String, ts: String, text: String, editedTS: String) throws {
        try db.transaction {
            guard let id = try db.query("SELECT id FROM messages WHERE channel=? AND ts=?", channel, ts, map: { $0.int64(0) }).first else { return }
            try db.run("UPDATE messages SET text=?, edited=1, edited_ts=? WHERE id=?", text, editedTS, id)
            try db.run("DELETE FROM msg_fts WHERE rowid=?", id)
            try db.run("INSERT INTO msg_fts(rowid, text) VALUES(?,?)", id, Mrkdwn.plain(text, names: name(of:)))
        }
    }

    // MARK: reactions

    public func reactions(channel: String, ts: String) throws -> [SlackReaction]? {
        guard let row = try db.query("SELECT reactions FROM messages WHERE channel=? AND ts=?", channel, ts, map: { $0.string(0) }).first else { return nil }
        return try row.map { try JSONDecoder().decode([SlackReaction].self, from: Data($0.utf8)) } ?? []
    }

    public func setReactions(channel: String, ts: String, _ rs: [SlackReaction]) throws {
        try db.run("UPDATE messages SET reactions=? WHERE channel=? AND ts=?",
                   rs.isEmpty ? nil : String(decoding: try JSONEncoder().encode(rs), as: UTF8.self), channel, ts)
    }

    /// Adds or removes one user's reaction. Idempotent; false when nothing changed
    /// (or the message isn't cached).
    @discardableResult
    public func applyReaction(channel: String, ts: String, name: String, user: String, add: Bool) throws -> Bool {
        try db.transaction {
            guard var rs = try reactions(channel: channel, ts: ts) else { return false }
            let i = rs.firstIndex { $0.name == name }
            if add {
                if let i {
                    if rs[i].users?.contains(user) == true { return false }
                    rs[i].count += 1
                    rs[i].users = (rs[i].users ?? []) + [user]
                } else {
                    rs.append(SlackReaction(name: name, count: 1, users: [user]))
                }
            } else {
                guard let i, rs[i].users?.contains(user) ?? false else { return false }
                rs[i].count -= 1
                rs[i].users?.removeAll { $0 == user }
                if rs[i].count <= 0 { rs.remove(at: i) }
            }
            try setReactions(channel: channel, ts: ts, rs)
            return true
        }
    }

    /// Records how far history has been fetched in each direction.
    public func markSynced(_ channel: String, newest: String?, oldest: String?, complete: Bool?) throws {
        if let newest { try db.run("UPDATE convs SET synced=max(coalesce(synced,'0'), ?) WHERE id=?", newest, channel) }
        if let oldest { try db.run("UPDATE convs SET oldest=CASE WHEN oldest IS NULL OR ? < oldest THEN ? ELSE oldest END WHERE id=?", oldest, oldest, channel) }
        if let complete { try db.run("UPDATE convs SET complete=? WHERE id=?", complete, channel) }
    }

    // MARK: message reads

    static let messageColumns = """
        id, channel, ts, thread_ts, user, text, subtype, reply_count, latest_reply, edited_ts, reactions,
        bot_id, username, attachments, reply_users
        """

    /// What every row of one read shares, looked up once.
    struct Reader {
        let me: String
        let mentions: [String]
        let people: [String: Person]
        let bots: [String: Bot]
        let dec = JSONDecoder()

        func mentionsMe(_ text: String) -> Bool {
            text.utf8.contains(UInt8(ascii: "<")) && mentions.contains { text.contains($0) }
        }
    }

    func reader() -> Reader {
        let me = self.me ?? ""
        let groups = myGroups().sorted().map { "<!subteam^\($0)" }
        return Reader(me: me, mentions: (me.isEmpty ? [] : ["<@\(me)>", "<@\(me)|"]) + ["<!here", "<!channel", "<!everyone"] + groups,
                      people: peopleSnapshot(), bots: botsSnapshot())
    }

    private func message(_ r: Row, _ ctx: Reader) -> Message {
        func decode<T: Decodable>(_ i: Int32, _ t: T.Type) -> T? {
            guard let s = r.string(i) else { return nil }
            do { return try ctx.dec.decode(T.self, from: Data(s.utf8)) } catch {
                log("message \(r.text(1))/\(r.text(2)) column \(i): \(error)")
                return nil
            }
        }
        let user = r.text(4), botID = r.string(11), text = r.text(5)
        let person = user.isEmpty ? nil : ctx.people[user]
        let bot = botID.flatMap { ctx.bots[$0] }
        let author = person?.label ?? bot?.name ?? r.string(12) ?? (user.isEmpty ? botID ?? "" : user)
        return Message(
            id: r.int64(0), channel: r.text(1), ts: r.text(2), threadTS: r.string(3), user: user, author: author, text: text,
            subtype: r.string(6), replyCount: r.int(7), latestReply: r.string(8), reactions: decode(10, [SlackReaction].self) ?? [],
            editedTS: r.string(9), botID: botID, isBot: botID != nil || person?.isBot == true,
            avatar: person?.image48 ?? bot?.image48, isMine: !ctx.me.isEmpty && user == ctx.me,
            mentionsMe: user != ctx.me && ctx.mentionsMe(text),
            replyUsers: Array((decode(14, [String].self) ?? []).prefix(3)),
            unfurls: (decode(13, [SlackMessage.Attachment].self) ?? []).map(Unfurl.init))
    }

    private func rows(_ sql: String, _ args: [SQLBindable]) throws -> [Message] {
        let ctx = reader()
        return try db.query(sql, args) { message($0, ctx) }
    }

    /// The newest `limit` top-level messages plus local echo, oldest first for drawing.
    public func messages(_ channel: String, limit: Int = 200) throws -> [Message] {
        let ms = try rows("""
            SELECT \(Self.messageColumns) FROM messages
            WHERE channel=? AND (thread_ts IS NULL OR thread_ts = ts) ORDER BY ts DESC LIMIT ?
            """, [channel, limit]).reversed()
        return try withEcho(Array(ms), channel: channel, thread: nil, sends: true)
    }

    /// One page further back, oldest first.
    public func messages(_ channel: String, before ts: String, limit: Int) throws -> [Message] {
        let ms = try rows("""
            SELECT \(Self.messageColumns) FROM messages
            WHERE channel=? AND ts < ? AND (thread_ts IS NULL OR thread_ts = ts) ORDER BY ts DESC LIMIT ?
            """, [channel, ts, limit]).reversed()
        return try withEcho(Array(ms), channel: channel, thread: nil, sends: false)
    }

    public func thread(_ channel: String, ts: String) throws -> [Message] {
        let ms = try rows("SELECT \(Self.messageColumns) FROM messages WHERE channel=? AND (ts=? OR thread_ts=?) ORDER BY ts", [channel, ts, ts])
        return try withEcho(ms, channel: channel, thread: ts, sends: true)
    }

    public func message(_ channel: String, ts: String) throws -> Message? {
        let ms = try rows("SELECT \(Self.messageColumns) FROM messages WHERE channel=? AND ts=?", [channel, ts])
        return try withEcho(ms, channel: channel, thread: nil, sends: false).first
    }

    /// Oldest top-level ts past the read cursor that isn't mine; nil if none.
    public func firstUnread(_ channel: String) throws -> String? {
        try db.string("""
            SELECT min(m.ts) FROM messages m JOIN convs c ON c.id = m.channel
            WHERE m.channel=? AND m.ts > max(c.last_read, c.seen) AND (m.thread_ts IS NULL OR m.thread_ts = m.ts)
              AND m.user != ? AND coalesce(m.subtype,'') NOT IN ('channel_join','channel_leave','channel_topic','channel_purpose')
            """, channel, me ?? "")
    }

    /// Oldest reply past my last view of the thread (or, never viewed, past
    /// the channel's read cursor) that isn't mine.
    public func firstUnread(_ channel: String, thread ts: String) throws -> String? {
        let read = try ui(.threadRead(channel, ts)) ?? (try conversation(channel)?.lastRead) ?? "0"
        return try db.string("""
            SELECT min(ts) FROM messages WHERE channel=? AND thread_ts=? AND ts != thread_ts AND ts > ? AND user != ?
            """, channel, ts, read, me ?? "")
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
