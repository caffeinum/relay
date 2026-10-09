import Foundation

public enum SyncError: Error, CustomStringConvertible {
    case notSignedIn
    case notCached(channel: String, ts: String)
    case partial([(id: String, error: String)], of: Int)
    public var description: String {
        switch self {
        case .partial(let failed, let total):
            let list = failed.prefix(5).map { "\($0.id): \($0.error)" }.joined(separator: ", ")
            return "\(failed.count) of \(total) conversations failed to sync (\(list)\(failed.count > 5 ? ", …" : ""))"
        case .notSignedIn: return "the cache doesn't know who I am yet; sync first"
        case .notCached(let c, let ts): return "message \(c)/\(ts) is not in the cache"
        }
    }
}

/// Brings the cache up to date when the app opens, and on demand. No
/// background process: nothing runs while the app is closed.
public final class Sync {
    public let store: Store
    public let slack: Slack
    /// Called on the main queue with the channels whose messages changed;
    /// an empty set means the conversation list itself changed.
    public var onChange: ((Set<String>) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onProgress: ((String?) -> Void)?

    /// Calls in flight at once. Slack's Tier 3 is ~50 a minute per method;
    /// 429s are waited out by the client.
    public var width = 4

    static let day: TimeInterval = 86_400
    let marks = MarkThrottle()
    private let lock = NSLock()
    private var attempted = Set<String>()
    private var unavailableLogged = Set<String>()

    public init(store: Store, slack: Slack) {
        self.store = store
        self.slack = slack
    }

    func changed(_ s: Set<String>) {
        guard let onChange else { return }
        DispatchQueue.main.async { onChange(s) }
    }

    func progress(_ s: String?) {
        guard let onProgress else { return }
        DispatchQueue.main.async { onProgress(s) }
    }

    func report(_ error: Error, _ context: String) {
        log("\(context): \(error)")
        if let onError { DispatchQueue.main.async { onError(error) } }
    }

    /// Everything: who I am, people, conversations, then each conversation's
    /// read cursor and newest messages. `first` goes before the rest.
    public func all(first: String? = nil) async throws {
        progress("Connecting…")
        let auth = try await slack.authTest()
        try store.setValue("me", auth.user_id)
        try store.setValue("team", auth.team ?? auth.team_id)
        if let u = auth.url { try store.setValue("url", u) }
        progress("People…")
        try store.put(users: try await slack.users())
        progress("Channels…")
        let convs = try await slack.conversations()
        try store.put(conversations: convs, me: auth.user_id)
        changed([])
        await directory()

        var order = convs.map(\.id)
        if let first, let i = order.firstIndex(of: first) { order.remove(at: i); order.insert(first, at: 0) }
        var done = 0
        var failed: [(String, Error)] = []
        await withTaskGroup(of: (String, Error?).self) { group in
            var next = order.makeIterator()
            func add() {
                guard let id = next.next() else { return }
                group.addTask {
                    do { try await self.conversation(id); return (id, nil) } catch { return (id, error) }
                }
            }
            for _ in 0..<width { add() }
            while let (id, error) = await group.next() {
                done += 1
                if let error { failed.append((id, error)) } else { changed([id]) }
                progress("Syncing \(done)/\(order.count)…")
                add()
            }
        }
        progress(nil)
        if failed.count == order.count, let (_, error) = failed.first { throw error }
        try store.setValue("synced_at", String(Int(Date().timeIntervalSince1970)))
        if !failed.isEmpty { throw SyncError.partial(failed.map { ($0.0, String(describing: $0.1)) }, of: order.count) }
    }

    /// The read cursor and anything newer than what's cached.
    public func conversation(_ id: String) async throws {
        let info: SlackConversation
        do { info = try await slack.info(id) } catch SlackError.api(_, "channel_not_found", _) {
            log("conversations.info \(id): channel_not_found, hiding it")
            try store.hide(conversation: id)
            changed([])
            return
        }
        if let lr = info.last_read { try store.setLastRead(id, lr) }
        try await newer(id)
    }

    public func newer(_ id: String) async throws {
        let state = store.syncState(id)
        guard let synced = state.synced else {
            let h = try await slack.history(id, limit: 100)
            try store.put(messages: h.messages, channel: id)
            try store.markSynced(id, newest: h.messages.map(\.ts).max() ?? "0", oldest: h.messages.map(\.ts).min(),
                                 complete: !(h.has_more ?? false))
            await resolve(h.messages, channel: id)
            return
        }
        var oldest = synced
        var fetched: [SlackMessage] = []
        for _ in 0..<10 {
            let h = try await slack.history(id, oldest: oldest, limit: 200)
            try store.put(messages: h.messages, channel: id)
            fetched += h.messages
            guard let top = h.messages.map(\.ts).max() else { break }
            try store.markSynced(id, newest: top, oldest: nil, complete: nil)
            oldest = top
            if h.has_more != true { break }
        }
        await resolve(fetched, channel: id)
    }

    /// One page further back. Returns false when the start is reached.
    @discardableResult
    public func older(_ id: String) async throws -> Bool {
        let state = store.syncState(id)
        if state.complete { return false }
        let h = try await slack.history(id, latest: state.oldest, limit: 200)
        try store.put(messages: h.messages, channel: id)
        try store.markSynced(id, newest: nil, oldest: h.messages.map(\.ts).min(), complete: !(h.has_more ?? false))
        changed([id])
        await resolve(h.messages, channel: id)
        return h.has_more ?? false
    }

    public func thread(_ channel: String, ts: String) async throws {
        let ms = try await slack.replies(channel, ts: ts)
        try store.put(messages: ms, channel: channel)
        changed([channel])
        await resolve(ms, channel: channel)
    }

    /// Slack's own search, for what the cache hasn't seen.
    public func remoteSearch(_ query: String) async throws -> [Hit] {
        let r = try await slack.search(query)
        return r.messages.matches.map { m in
            Hit(channel: m.channel.id, channelName: m.channel.name.map { "#\($0)" } ?? m.channel.id, ts: m.ts,
                author: m.user.map(store.name(of:)) ?? m.username ?? "", text: m.text ?? "", remote: true)
        }
    }

    /// Fire and forget from the UI; failures go to onError.
    public func run(_ work: @escaping (Sync) async throws -> Void) {
        Task {
            do { try await work(self) } catch {
                progress(nil)
                report(error, "sync")
            }
        }
    }

    // MARK: directory

    /// User groups and custom emoji, at most once a day. A method the
    /// workspace (or emulator) doesn't have leaves its table empty and says
    /// why in kv `<name>.unavailable`; nothing stands in for it.
    public func directory(force: Bool = false) async {
        if !force, let at = store.get("directory.synced_at").flatMap(Double.init), Date().timeIntervalSince1970 - at < Self.day { return }
        await fetch("usergroups") { try self.store.put(usergroups: try await self.slack.usergroups(), replacing: true) }
        await fetch("emoji") { try self.store.put(emoji: try await self.slack.emoji(), replacing: true) }
        do { try store.setValue("directory.synced_at", String(Date().timeIntervalSince1970)) } catch { report(error, "directory") }
        changed([])
    }

    private func fetch(_ name: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            try store.setValue("\(name).unavailable", nil)
        } catch {
            let first = lock.withLock { unavailableLogged.insert(name).inserted }
            if first { log("\(name) unavailable: \(error)") }
            do { try store.setValue("\(name).unavailable", "\(error)") } catch { report(error, name) }
        }
    }

    /// Fetches people and bots the cache hasn't seen: authors, and every
    /// `<@U>` in the text. Each id is tried once per process.
    func resolve(_ ms: [SlackMessage], channel: String) async {
        var users = Set<String>(), bots = Set<String>()
        for m in ms {
            if let u = m.user, store.person(u) == nil { users.insert(u) }
            if let b = m.bot_id, m.bot_profile == nil, store.bot(b) == nil { bots.insert(b) }
            for id in Self.mentionedUsers(m.text ?? "") where store.person(id) == nil { users.insert(id) }
        }
        let todo = lock.withLock {
            let u = users.subtracting(attempted), b = bots.subtracting(attempted)
            attempted.formUnion(u); attempted.formUnion(b)
            return (u, b)
        }
        guard !todo.0.isEmpty || !todo.1.isEmpty else { return }
        var found = false
        for id in todo.0.sorted() {
            do { try store.put(users: [try await slack.user(id)]); found = true } catch { report(error, "users.info \(id)") }
        }
        for id in todo.1.sorted() {
            do { try store.put(bots: [try await slack.bot(id)]); found = true } catch { report(error, "bots.info \(id)") }
        }
        if found { changed([channel]) }
    }

    static func mentionedUsers(_ text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let r = rest.range(of: "<@") {
            let id = rest[r.upperBound...].prefix { $0.isLetter || $0.isNumber }
            if !id.isEmpty { out.append(String(id)) }
            rest = rest[r.upperBound...]
        }
        return out
    }
}

/// conversations.mark at most once per channel per 3 s: the first call goes
/// now, later ones in the window collapse into one trailing call.
final class MarkThrottle {
    static let window: TimeInterval = 3
    private let lock = NSLock()
    private var last: [String: Date] = [:]
    private var waiting: [String: String] = [:]

    enum Decision: Equatable { case now, later(TimeInterval), merged }

    func request(_ channel: String, ts: String, at now: Date = Date()) -> Decision {
        lock.withLock {
            if let pending = waiting[channel] {
                waiting[channel] = max(pending, ts)
                return .merged
            }
            if let l = last[channel], now.timeIntervalSince(l) < Self.window {
                waiting[channel] = ts
                return .later(Self.window - now.timeIntervalSince(l))
            }
            last[channel] = now
            return .now
        }
    }

    /// The trailing call is due: the newest ts asked for in the window.
    func take(_ channel: String, at now: Date = Date()) -> String? {
        lock.withLock {
            guard let ts = waiting.removeValue(forKey: channel) else { return nil }
            last[channel] = now
            return ts
        }
    }
}

