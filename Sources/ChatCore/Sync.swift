import Foundation

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

    public init(store: Store, slack: Slack) {
        self.store = store
        self.slack = slack
    }

    private func changed(_ s: Set<String>) {
        guard let onChange else { return }
        DispatchQueue.main.async { onChange(s) }
    }

    private func progress(_ s: String?) {
        guard let onProgress else { return }
        DispatchQueue.main.async { onProgress(s) }
    }

    /// Everything: who I am, people, conversations, then each conversation's
    /// read cursor and newest messages. `first` goes before the rest.
    public func all(first: String? = nil) async throws {
        progress("Connecting…")
        let auth = try await slack.authTest()
        store.set("me", auth.user_id)
        store.set("team", auth.team ?? auth.team_id)
        if let u = auth.url { store.set("url", u) }
        progress("People…")
        try store.put(users: try await slack.users())
        progress("Channels…")
        let convs = try await slack.conversations()
        try store.put(conversations: convs, me: auth.user_id)
        changed([])

        var order = convs.map(\.id)
        if let first, let i = order.firstIndex(of: first) { order.remove(at: i); order.insert(first, at: 0) }
        var done = 0
        try await withThrowingTaskGroup(of: String.self) { group in
            var next = order.makeIterator()
            func add() { if let id = next.next() { group.addTask { try await self.conversation(id); return id } } }
            for _ in 0..<width { add() }
            while let id = try await group.next() {
                done += 1
                progress("Syncing \(done)/\(order.count)…")
                changed([id])
                add()
            }
        }
        store.set("synced_at", String(Int(Date().timeIntervalSince1970)))
        progress(nil)
    }

    /// The read cursor and anything newer than what's cached.
    public func conversation(_ id: String) async throws {
        let info = try await slack.info(id)
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
            return
        }
        var oldest = synced
        for _ in 0..<10 {
            let h = try await slack.history(id, oldest: oldest, limit: 200)
            try store.put(messages: h.messages, channel: id)
            guard let top = h.messages.map(\.ts).max() else { break }
            try store.markSynced(id, newest: top, oldest: nil, complete: nil)
            oldest = top
            if h.has_more != true { break }
        }
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
        return h.has_more ?? false
    }

    public func thread(_ channel: String, ts: String) async throws {
        try store.put(messages: try await slack.replies(channel, ts: ts), channel: channel)
        changed([channel])
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
                log("sync: \(error)")
                progress(nil)
                if let onError { DispatchQueue.main.async { onError(error) } }
            }
        }
    }
}
