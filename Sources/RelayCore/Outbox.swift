import Foundation

public enum OutboxKind: String, Codable { case send, edit, delete }
public enum OutboxState: String, Codable { case pending, sending, sent, failed, cancelled }

public struct LocalEcho: Equatable {
    public var outbox: Int64
    public var kind: OutboxKind
    /// Only pending, sending and failed reach the UI.
    public var state: OutboxState
    /// Pending only: the end of the undo window.
    public var sendsAt: Date?
    /// Failed only, Slack's error word for word.
    public var error: String?
    /// Edit: the text before the edit.
    public var original: String?

    public init(outbox: Int64, kind: OutboxKind, state: OutboxState, sendsAt: Date? = nil, error: String? = nil, original: String? = nil) {
        self.outbox = outbox; self.kind = kind; self.state = state; self.sendsAt = sendsAt; self.error = error; self.original = original
    }
}

public struct OutboxItem: Equatable {
    public var id: Int64; public var kind: OutboxKind; public var state: OutboxState
    public var channel: String; public var threadTS: String?
    /// Edit/delete: the message. Send: nil until sent.
    public var targetTS: String?
    /// Send: the ordering ts of the echo.
    public var localTS: String
    public var text: String?; public var original: String?; public var error: String?
    public var created: Date; public var sendsAt: Date

    var echo: LocalEcho {
        LocalEcho(outbox: id, kind: kind, state: state, sendsAt: state == .pending ? sendsAt : nil,
                  error: state == .failed ? error : nil, original: kind == .edit ? original : nil)
    }
}

public enum UndoResult: Equatable { case undone(OutboxItem), tooLate(OutboxItem), nothing }

public enum OutboxError: Error, CustomStringConvertible {
    case notMine, notFound(Int64), notPending(Int64)
    public var description: String {
        switch self {
        case .notMine: return "You can only edit your own messages"
        case .notFound(let id): return "outbox item \(id) doesn't exist"
        case .notPending(let id): return "outbox item \(id) is not in a state that allows this"
        }
    }
}

/// Sends, edits and deletes wait out an undo window in sqlite, then go to
/// Slack. Every state lives in the outbox table, so a quit loses nothing:
/// the next launch shows unsent items as failed and never sends them on its own.
public final class Outbox {
    public let store: Store
    public let slack: Slack
    public var undoSeconds: Double
    /// Main queue; the channels to redraw.
    public var onChange: ((Set<String>) -> Void)?
    /// Main queue; the caller toasts and logs.
    public var onError: ((OutboxItem, Error) -> Void)?
    private let timers = DispatchQueue(label: "\(Brand.bundleID).outbox")

    public static let quitError = "not sent: app quit"
    static let tooLateWindow: TimeInterval = 30

    public init(store: Store, slack: Slack, undoSeconds: Double = 5) {
        self.store = store
        self.slack = slack
        self.undoSeconds = undoSeconds
    }

    private var db: Database { store.db }

    /// Throws writeBlocked synchronously when writes are off; nothing is stored.
    /// Clears that draft in the same transaction.
    @discardableResult
    public func send(channel: String, thread: String?, text: String) throws -> OutboxItem {
        try slack.gate("chat.postMessage")
        let item = try db.transaction {
            let id = try insert(.send, channel: channel, thread: thread, target: nil, text: text, original: nil)
            try store.clearDraft(channel, thread: thread)
            return try find(id)
        }
        schedule(item)
        return item
    }

    @discardableResult
    public func edit(_ m: Message, text: String) throws -> OutboxItem {
        try slack.gate("chat.update")
        try own(m)
        let item = try db.transaction { try find(try insert(.edit, channel: m.channel, thread: m.threadTS, target: m.ts, text: text, original: m.local?.original ?? m.text)) }
        schedule(item)
        return item
    }

    @discardableResult
    public func delete(_ m: Message) throws -> OutboxItem {
        try slack.gate("chat.delete")
        try own(m)
        let item = try db.transaction { try find(try insert(.delete, channel: m.channel, thread: m.threadTS, target: m.ts, text: nil, original: m.text)) }
        schedule(item)
        return item
    }

    /// The newest pending item is cancelled. When nothing is pending, the
    /// newest item that went out in the last 30 s comes back as tooLate.
    public func undo() throws -> UndoResult {
        let r: UndoResult = try db.transaction {
            if let id = try db.query("SELECT id FROM outbox WHERE state='pending' ORDER BY id DESC LIMIT 1", map: { $0.int64(0) }).first {
                try db.run("UPDATE outbox SET state='cancelled' WHERE id=?", id)
                return .undone(try find(id))
            }
            let since = Date().addingTimeInterval(-Self.tooLateWindow).timeIntervalSince1970
            if let id = try db.query("""
                SELECT id FROM outbox WHERE state IN ('sending','sent') AND sends_at > ? ORDER BY id DESC LIMIT 1
                """, since, map: { $0.int64(0) }).first {
                return .tooLate(try find(id))
            }
            return .nothing
        }
        if case .undone(let item) = r { changed([item.channel]) }
        return r
    }

    /// failed → pending, with a fresh window.
    public func retry(_ id: Int64) throws {
        let item = try db.transaction {
            _ = try find(id)
            guard try db.update("UPDATE outbox SET state='pending', error=NULL, sends_at=? WHERE id=? AND state='failed'",
                                Date().addingTimeInterval(undoSeconds).timeIntervalSince1970, id) == 1 else { throw OutboxError.notPending(id) }
            return try find(id)
        }
        schedule(item)
    }

    /// failed → cancelled; the echo goes away.
    public func discard(_ id: Int64) throws {
        let item = try db.transaction {
            _ = try find(id)
            guard try db.update("UPDATE outbox SET state='cancelled' WHERE id=? AND state='failed'", id) == 1 else { throw OutboxError.notPending(id) }
            return try find(id)
        }
        changed([item.channel])
    }

    /// At launch: whatever was waiting or in flight when the app quit is
    /// failed, for the user to retry. Nothing is sent on its own.
    public func resume() throws {
        let n = try db.update("UPDATE outbox SET state='failed', error=? WHERE state IN ('pending','sending')", Self.quitError)
        if n > 0 { log("outbox: \(n) item(s) left unsent at quit, marked failed") }
    }

    public func items(channel: String) throws -> [OutboxItem] {
        try store.outbox(where: "channel=?", [channel])
    }

    public func items() throws -> [OutboxItem] { try store.outbox(where: "1", []) }

    // MARK: sending

    /// Sends the item now if it is still pending; the timer calls this at
    /// the end of the window. Safe to call twice: only one call moves it to sending.
    public func fire(_ id: Int64) async {
        let item: OutboxItem
        do {
            guard try db.update("UPDATE outbox SET state='sending' WHERE id=? AND state='pending'", id) == 1 else { return }
            item = try find(id)
        } catch {
            log("outbox \(id): \(error)")
            return
        }
        changed([item.channel])
        do {
            try await perform(item)
        } catch {
            let word = (error as? SlackError)?.code ?? "\(error)"
            log("outbox \(item.kind.rawValue) \(item.channel) failed: \(error)")
            do { try db.run("UPDATE outbox SET state='failed', error=? WHERE id=? AND state='sending'", word, id) } catch {
                log("outbox \(id): \(error)")
            }
            let failed = (try? find(id)) ?? item
            if let onError { DispatchQueue.main.async { onError(failed, error) } }
        }
        changed([item.channel])
    }

    private func perform(_ item: OutboxItem) async throws {
        switch item.kind {
        case .send:
            let text = try require(item.text, item)
            let posted = try await slack.post(channel: item.channel, text: text, thread: item.threadTS)
            var m = posted.message ?? SlackMessage(ts: posted.ts, user: store.me, text: text, thread_ts: item.threadTS)
            if m.thread_ts == nil { m.thread_ts = item.threadTS }
            try db.transaction {
                try store.put(messages: [m], channel: item.channel, resolvingEchoes: false)
                try db.run("UPDATE outbox SET state='sent', sent_ts=? WHERE id=?", posted.ts, item.id)
            }
        case .edit:
            let text = try require(item.text, item), ts = try require(item.targetTS, item)
            try await slack.update(channel: item.channel, ts: ts, text: text)
            try db.transaction {
                try store.applyEdit(channel: item.channel, ts: ts, text: text, editedTS: slackTS())
                try db.run("UPDATE outbox SET state='sent' WHERE id=?", item.id)
            }
        case .delete:
            let ts = try require(item.targetTS, item)
            try await slack.delete(channel: item.channel, ts: ts)
            try db.transaction {
                try store.delete(channel: item.channel, ts: ts)
                try db.run("UPDATE outbox SET state='sent' WHERE id=?", item.id)
            }
        }
    }

    private func require<T>(_ v: T?, _ item: OutboxItem) throws -> T {
        guard let v else { throw OutboxError.notFound(item.id) }
        return v
    }

    private func schedule(_ item: OutboxItem) {
        changed([item.channel])
        let delay = max(0, item.sendsAt.timeIntervalSinceNow)
        timers.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            Task { await self.fire(item.id) }
        }
    }

    // MARK: rows

    private func own(_ m: Message) throws {
        guard m.local?.kind != .send, m.id > 0 else { throw OutboxError.notFound(m.id) }
        guard let me = store.me, m.user == me else { throw OutboxError.notMine }
    }

    private func insert(_ kind: OutboxKind, channel: String, thread: String?, target: String?, text: String?, original: String?) throws -> Int64 {
        let now = Date()
        return try db.insert("""
            INSERT INTO outbox(kind,state,channel,thread_ts,target_ts,local_ts,text,original,created,sends_at)
            VALUES(?,'pending',?,?,?,?,?,?,?,?)
            """, kind.rawValue, channel, thread, target, slackTS(now), text, original, now.timeIntervalSince1970,
                 now.addingTimeInterval(undoSeconds).timeIntervalSince1970)
    }

    private func find(_ id: Int64) throws -> OutboxItem {
        guard let item = try store.outbox(where: "id=?", [id]).first else { throw OutboxError.notFound(id) }
        return item
    }

    private func changed(_ s: Set<String>) {
        guard let onChange else { return }
        DispatchQueue.main.async { onChange(s) }
    }
}

extension Store {
    func outbox(where filter: String, _ args: [SQLBindable]) throws -> [OutboxItem] {
        try db.query("""
            SELECT id, kind, state, channel, thread_ts, coalesce(target_ts, sent_ts), local_ts, text, original, error, created, sends_at
            FROM outbox WHERE \(filter) ORDER BY id
            """, args) { r in
            guard let kind = OutboxKind(rawValue: r.text(1)), let state = OutboxState(rawValue: r.text(2)) else {
                throw SQLiteError.step("outbox row \(r.int64(0)) has kind \(r.text(1)) state \(r.text(2))", sql: "outbox")
            }
            return OutboxItem(id: r.int64(0), kind: kind, state: state, channel: r.text(3), threadTS: r.string(4), targetTS: r.string(5),
                              localTS: r.text(6), text: r.string(7), original: r.string(8), error: r.string(9),
                              created: Date(timeIntervalSince1970: r.double(10)), sendsAt: Date(timeIntervalSince1970: r.double(11)))
        }
    }

    /// Lays the outbox over server rows: edits replace text, deletes mark
    /// the row, and (when `sends`) unsent messages for this list are appended.
    func withEcho(_ ms: [Message], channel: String, thread: String?, sends: Bool) throws -> [Message] {
        let live = try outbox(where: "channel=? AND state IN ('pending','sending','failed')", [channel])
        guard !live.isEmpty else { return ms }
        var out = ms
        let index = Dictionary(ms.enumerated().map { ($1.ts, $0) }, uniquingKeysWith: { a, _ in a })
        var appended = false
        let me = self.me ?? ""
        for item in live {
            switch item.kind {
            case .edit, .delete:
                guard let ts = item.targetTS, let i = index[ts] else { continue }
                if item.kind == .edit, let text = item.text {
                    out[i].text = text
                    out[i].editedTS = item.localTS
                }
                out[i].local = item.echo
            case .send:
                guard sends, item.threadTS == thread, let text = item.text else { continue }
                out.append(Message(id: -item.id, channel: channel, ts: item.localTS, threadTS: item.threadTS, user: me,
                                   author: name(of: me), text: text, avatar: person(me)?.image48, isMine: true, local: item.echo))
                appended = true
            }
        }
        if appended { out.sort { $0.ts < $1.ts } }
        return out
    }
}
