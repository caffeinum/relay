import Foundation

/// A transport error with the URL (and its ticket) taken out.
public struct LiveFailure: Error, CustomStringConvertible { public let description: String }

public enum LiveError: Error, CustomStringConvertible {
    case malformed(String)
    public var description: String {
        switch self { case .malformed(let s): return "socket mode: \(s)" }
    }
}

/// Applies Events API payloads (from Socket Mode) to the store. Pure apart
/// from the store; every event id is applied once.
public enum EventApplier {
    /// Returns the channels touched; empty for directory events and repeats.
    public static func apply(_ payload: Data, to store: Store) throws -> Set<String> {
        try applied(payload, to: store) ?? []
    }

    /// `{"envelope_id": …}` for an envelope, sent back within 3 s.
    public static func ack(for envelope: Data) throws -> Data {
        guard let o = try JSONSerialization.jsonObject(with: envelope) as? [String: Any], let id = o["envelope_id"] as? String else {
            throw LiveError.malformed("envelope has no envelope_id")
        }
        return try JSONSerialization.data(withJSONObject: ["envelope_id": id])
    }

    static let dedupWindow: TimeInterval = 3600

    private struct Callback: Decodable { var event_id: String?; var event: Head }
    private struct Head: Decodable { var type: String; var subtype: String? }
    private struct Body<E: Decodable>: Decodable { var event: E }
    private struct ChannelMessage: Decodable { var channel: String }
    private struct Changed: Decodable { var channel: String; var message: SlackMessage }
    private struct Deleted: Decodable { var channel: String; var deleted_ts: String }
    private struct Reaction: Decodable {
        struct Item: Decodable { var type: String; var channel: String?; var ts: String? }
        var user: String; var reaction: String; var item: Item
    }
    private struct Marked: Decodable { var channel: String; var ts: String }
    private struct Joined: Decodable { var channel: String; var user: String }
    private struct UserChange: Decodable { var user: SlackUser }
    private struct EmojiChange: Decodable { var subtype: String?; var name: String?; var value: String?; var names: [String]?; var old_name: String?; var new_name: String? }
    private struct Subteam: Decodable { var subteam: SlackUserGroup }

    /// nil: ignored (a repeat, or an event Relay doesn't use).
    static func applied(_ payload: Data, to store: Store) throws -> Set<String>? {
        let dec = JSONDecoder()
        let cb: Callback
        do { cb = try dec.decode(Callback.self, from: payload) } catch { throw LiveError.malformed("payload: \(error)") }
        func body<E: Decodable>(_ t: E.Type) throws -> E {
            do { return try dec.decode(Body<E>.self, from: payload).event } catch {
                throw LiveError.malformed("\(cb.event.type)/\(cb.event.subtype ?? "-"): \(error)")
            }
        }
        return try store.db.transaction {
            if let id = cb.event_id {
                let now = Date().timeIntervalSince1970
                try store.db.run("DELETE FROM events WHERE at < ?", now - dedupWindow)
                guard try store.db.update("INSERT OR IGNORE INTO events(id, at) VALUES(?, ?)", id, now) == 1 else { return nil }
            }
            switch cb.event.type {
            case "message":
                switch cb.event.subtype {
                case "message_changed", "message_replied":
                    let e = try body(Changed.self)
                    try store.put(messages: [e.message], channel: e.channel)
                    return [e.channel]
                case "message_deleted":
                    let e = try body(Deleted.self)
                    try store.delete(channel: e.channel, ts: e.deleted_ts)
                    return [e.channel]
                default:
                    let c = try body(ChannelMessage.self).channel
                    let m = try body(SlackMessage.self)
                    let isReply = m.thread_ts.map { $0 != m.ts } ?? false
                    let isNewReply = try isReply && !store.exists(channel: c, ts: m.ts)
                    try store.put(messages: [m], channel: c)
                    if isNewReply, let parent = m.thread_ts {
                        try store.noteReply(channel: c, parent: parent, ts: m.ts, user: m.user ?? m.bot_id ?? "")
                    }
                    return [c]
                }
            case "reaction_added", "reaction_removed":
                let e = try body(Reaction.self)
                guard e.item.type == "message", let c = e.item.channel, let ts = e.item.ts else { return nil }
                try store.applyReaction(channel: c, ts: ts, name: e.reaction, user: e.user, add: cb.event.type == "reaction_added")
                return [c]
            case "channel_marked", "im_marked", "group_marked", "mpim_marked":
                let e = try body(Marked.self)
                try store.setLastRead(e.channel, e.ts)
                return [e.channel]
            case "member_joined_channel":
                let e = try body(Joined.self)
                try store.addMember(e.user, channel: e.channel)
                return [e.channel]
            case "user_change":
                try store.put(users: [try body(UserChange.self).user])
                return []
            case "emoji_changed":
                let e = try body(EmojiChange.self)
                switch e.subtype {
                case "add":
                    guard let n = e.name, let v = e.value else { throw LiveError.malformed("emoji_changed add without name/value") }
                    try store.put(emoji: [n: v], replacing: false)
                case "remove":
                    try store.removeEmoji(e.names ?? [])
                case "rename":
                    guard let old = e.old_name, let new = e.new_name, let v = e.value else { throw LiveError.malformed("emoji_changed rename without names") }
                    try store.removeEmoji([old])
                    try store.put(emoji: [new: v], replacing: false)
                default:
                    return nil
                }
                return []
            case "subteam_updated", "subteam_created":
                try store.put(usergroups: [try body(Subteam.self).subteam])
                return []
            default:
                return nil
            }
        }
    }
}

/// Live updates: Socket Mode when there's an app token, else a poll of
/// what's on screen. Never invents a token.
public final class Live {
    public enum Status: Equatable { case connecting, live, reconnecting(after: Double, error: String), polling(reason: String), stopped }

    public let store: Store
    public let sync: Sync
    private let appToken: String?
    /// Main queue.
    public var onStatus: ((Status) -> Void)?
    /// Main queue; same meaning as Sync.onChange.
    public var onChange: ((Set<String>) -> Void)?
    /// Main queue.
    public var onError: ((Error) -> Void)?
    /// Main queue: each applied event's type ("message/message_changed") and the channels it touched.
    public var onEvent: ((String, Set<String>) -> Void)?

    public var pollInterval: TimeInterval = 10
    static let maxBackoff: Double = 60

    private let queue = DispatchQueue(label: "\(Brand.bundleID).live")
    private let session = URLSession(configuration: .default)
    private var running = false
    private var socket: URLSessionWebSocketTask?
    private var backoff: Double = 1
    private var poller: DispatchSourceTimer?
    private var watched: (channel: String?, thread: String?) = (nil, nil)
    private var visible = true
    private var connectedOnce = false
    /// When the socket last went away: a long gap re-syncs every conversation.
    private var droppedAt: Date?
    private var pinger: DispatchSourceTimer?
    public var pingInterval: TimeInterval = 30

    /// nil app token → polling("no app token").
    public init(store: Store, sync: Sync, appToken: String?) {
        self.store = store
        self.sync = sync
        self.appToken = appToken
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            if appToken == nil { startPolling("no app token") } else { connect() }
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
            pinger?.cancel()
            pinger = nil
            poller?.cancel()
            poller = nil
            status(.stopped)
        }
    }

    /// What the poll refreshes, every ~10 s.
    public func watch(channel: String?, thread: String?) {
        queue.async { [self] in watched = (channel, thread) }
    }

    /// Polling pauses while the window is hidden.
    public func setVisible(_ v: Bool) {
        queue.async { [self] in visible = v }
    }

    // MARK: socket

    private func connect() {
        guard running, let appToken else { return }
        status(.connecting)
        Task {
            do {
                let url = try await sync.slack.connectionsOpen(appToken: appToken)
                queue.async { [self] in
                    guard running else { return }
                    let t = session.webSocketTask(with: url)
                    socket = t
                    t.resume()
                    receive(t)
                    startPinging(t)
                }
            } catch {
                queue.async { [self] in retry(after: error) }
            }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard t === self.socket else { return }
                switch result {
                case .success(let frame):
                    switch frame {
                    case .string(let s): self.handle(Data(s.utf8), on: t)
                    case .data(let d): self.handle(d, on: t)
                    @unknown default: break
                    }
                    if t === self.socket { self.receive(t) }
                case .failure(let e):
                    self.socket = nil
                    self.retry(after: e)
                }
            }
        }
    }

    private func handle(_ frame: Data, on t: URLSessionWebSocketTask) {
        let o: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else { throw LiveError.malformed("frame is not an object") }
            o = obj
        } catch { fail(error); return }
        switch o["type"] as? String {
        case "hello":
            log("socket mode: connected")
            backoff = 1
            status(.live)
            if connectedOnce { catchUp(gap: droppedAt.map { Date().timeIntervalSince($0) } ?? 0) }
            connectedOnce = true
            droppedAt = nil
        case "disconnect":
            log("socket mode: disconnect (\(o["reason"] as? String ?? "no reason")), reconnecting")
            if droppedAt == nil { droppedAt = Date() }
            socket = nil
            t.cancel(with: .goingAway, reason: nil)
            connect()
        default:
            guard o["envelope_id"] != nil else { return }
            do {
                t.send(.string(String(decoding: try EventApplier.ack(for: frame), as: UTF8.self))) { [weak self] e in
                    if let e { self?.fail(e) }
                }
                guard o["type"] as? String == "events_api", let payload = o["payload"] else { return }
                let data = try JSONSerialization.data(withJSONObject: payload)
                let t0 = DispatchTime.now()
                let touched = try EventApplier.applied(data, to: store)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
                if ms > 2 { log(String(format: "socket mode: event apply took %.1fms", ms)) }
                if let touched {
                    changed(touched)
                    let event = (payload as? [String: Any])?["event"] as? [String: Any]
                    let kind = [event?["type"] as? String, event?["subtype"] as? String].compactMap { $0 }.joined(separator: "/")
                    if let onEvent { DispatchQueue.main.async { onEvent(kind, touched) } }
                }
            } catch { fail(error) }
        }
    }

    /// Events sent while the socket was down never arrive: after a
    /// reconnect, fetch what's on screen and the conversation list.
    private func catchUp(gap: TimeInterval) {
        let (channel, thread) = watched
        log(String(format: "socket mode: reconnected after %.0fs, catching up", gap))
        Task {
            do {
                if let channel {
                    try await sync.newer(channel)
                    if let thread { try store.put(messages: try await sync.slack.replies(channel, ts: thread), channel: channel) }
                    changed([channel])
                }
                if gap > 60 { try await sync.all(first: channel) }
            } catch { fail(error) }
        }
    }

    /// A socket left half-open by sleep reads as live and delivers nothing;
    /// a ping that fails sends it through the usual retry.
    private func startPinging(_ t: URLSessionWebSocketTask) {
        pinger?.cancel()
        let p = DispatchSource.makeTimerSource(queue: queue)
        p.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        p.setEventHandler { [weak self, weak t] in
            guard let self, let t, t === self.socket else { return }
            t.sendPing { [weak self] err in
                guard let self, let err else { return }
                self.queue.async {
                    guard t === self.socket else { return }
                    self.socket = nil
                    t.cancel(with: .goingAway, reason: nil)
                    self.retry(after: err)
                }
            }
        }
        pinger = p
        p.resume()
    }

    private func retry(after error: Error) {
        guard running else { return }
        if droppedAt == nil { droppedAt = Date() }
        pinger?.cancel()
        pinger = nil
        let after = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        let why = Self.describe(error)
        log("socket mode: \(why); reconnecting in \(Int(after))s")
        status(.reconnecting(after: after, error: why))
        queue.asyncAfter(deadline: .now() + after) { [self] in connect() }
    }

    /// NSError's description carries the failing URL, and Socket Mode's
    /// wss URL holds a connection ticket: only domain, code and message
    /// reach the log and the status line.
    static func describe(_ error: Error) -> String {
        guard !(error is LiveError), !(error is SlackError) else { return "\(error)" }
        let e = error as NSError
        return "\(e.domain) \(e.code): \(e.localizedDescription)"
    }

    // MARK: polling

    private func startPolling(_ reason: String) {
        status(.polling(reason: reason))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        poller = t
        t.resume()
    }

    private func poll() {
        guard running, visible else { return }
        let (channel, thread) = watched
        guard let channel else { return }
        Task {
            do {
                try await sync.newer(channel)
                if let thread { try store.put(messages: try await sync.slack.replies(channel, ts: thread), channel: channel) }
                changed([channel])
            } catch { fail(error) }
        }
    }

    // MARK: callbacks

    private func status(_ s: Status) {
        guard let onStatus else { return }
        DispatchQueue.main.async { onStatus(s) }
    }

    private func changed(_ s: Set<String>) {
        guard let onChange else { return }
        DispatchQueue.main.async { onChange(s) }
    }

    private func fail(_ e: Error) {
        let shown: Error = e is LiveError || e is SlackError ? e : LiveFailure(description: Self.describe(e))
        log("live: \(shown)")
        guard let onError else { return }
        DispatchQueue.main.async { onError(shown) }
    }
}
