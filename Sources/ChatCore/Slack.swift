import Foundation

public enum SlackError: Error, CustomStringConvertible {
    case api(method: String, error: String, needed: String?)
    case http(method: String, status: Int, body: String)
    case decode(method: String, Error)
    case writeBlocked(String)

    public var description: String {
        switch self {
        case .api(let m, let e, let needed): return "\(m): \(e)" + (needed.map { " (needs \($0))" } ?? "")
        case .http(let m, let s, let b): return "\(m): http \(s) \(b.prefix(200))"
        case .decode(let m, let e): return "\(m): can't decode response: \(e)"
        case .writeBlocked(let m): return "\(m) is a write and writes are off for this workspace"
        }
    }

    public var code: String? { if case .api(_, let e, _) = self { return e }; return nil }
}

// MARK: wire types, only the fields we keep

public struct SlackUser: Codable {
    public struct Profile: Codable { public var display_name: String?; public var real_name: String? }
    public var id: String
    public var name: String
    public var real_name: String?
    public var deleted: Bool?
    public var is_bot: Bool?
    public var profile: Profile?
}

public struct SlackConversation: Codable {
    public var id: String
    public var name: String?
    public var is_channel: Bool?
    public var is_group: Bool?
    public var is_im: Bool?
    public var is_mpim: Bool?
    public var is_private: Bool?
    public var is_archived: Bool?
    public var is_member: Bool?
    public var user: String?
    public var last_read: String?
    public var unread_count: Int?
    public var unread_count_display: Int?

    public var kind: String {
        if is_im == true { return "im" }
        if is_mpim == true { return "mpim" }
        if is_private == true || is_group == true { return "private" }
        return "channel"
    }
}

public struct SlackReaction: Codable, Equatable {
    public var name: String
    public var count: Int
    public var users: [String]?
}

public struct SlackMessage: Codable {
    public struct Edited: Codable { public var ts: String }
    public var ts: String
    public var user: String?
    public var bot_id: String?
    public var username: String?
    public var text: String?
    public var thread_ts: String?
    public var reply_count: Int?
    public var latest_reply: String?
    public var subtype: String?
    public var edited: Edited?
    public var reactions: [SlackReaction]?
}

public struct SearchMatch: Codable {
    public struct Channel: Codable { public var id: String; public var name: String? }
    public var channel: Channel
    public var ts: String
    public var text: String?
    public var user: String?
    public var username: String?
    public var permalink: String?
}

struct Paged: Codable {
    struct Meta: Codable { var next_cursor: String? }
    var response_metadata: Meta?
    var cursor: String? { response_metadata?.next_cursor.flatMap { $0.isEmpty ? nil : $0 } }
}

struct WithCursor<Page: Decodable>: Decodable {
    let page: Page
    let meta: Paged
    init(from d: Decoder) throws { page = try Page(from: d); meta = try Paged(from: d) }
}

struct Envelope: Codable {
    var ok: Bool
    var error: String?
    var needed: String?
}

// MARK: client

/// The Web API over URLSession. Every method is a form POST with the user
/// token as bearer. 429s wait out Retry-After and go again. Anything not on
/// the read list is refused unless the workspace has writes on.
public final class Slack {
    public let base: URL
    private let token: String
    public let writes: Bool
    private let session: URLSession

    public static let reads: Set<String> = [
        "auth.test", "users.list", "users.info", "conversations.list", "users.conversations",
        "conversations.info", "conversations.history", "conversations.replies", "conversations.members",
        "search.messages", "team.info", "reactions.get", "apps.connections.open",
    ]

    public init(api: String, token: String, writes: Bool = false, session: URLSession = .shared) {
        base = URL(string: api.hasSuffix("/") ? api : api + "/")!
        self.token = token
        self.writes = writes
        self.session = session
    }

    public convenience init(config: Config, workspace: String? = nil) throws {
        let (name, w) = try config.current(workspace)
        self.init(api: w.api, token: try Config.token(name, w), writes: w.writes ?? false)
    }

    public func call<T: Decodable>(_ method: String, _ params: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        guard Self.reads.contains(method) || writes else { throw SlackError.writeBlocked(method) }
        var req = URLRequest(url: base.appendingPathComponent(method))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)

        for attempt in 0..<5 {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(1 << attempt)
                log("\(method): rate limited, waiting \(wait)s")
                try await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                continue
            }
            guard status == 200 else { throw SlackError.http(method: method, status: status, body: String(decoding: data, as: UTF8.self)) }
            let env: Envelope
            do { env = try JSONDecoder().decode(Envelope.self, from: data) } catch { throw SlackError.decode(method: method, error) }
            guard env.ok else { throw SlackError.api(method: method, error: env.error ?? "unknown_error", needed: env.needed) }
            do { return try JSONDecoder().decode(T.self, from: data) } catch { throw SlackError.decode(method: method, error) }
        }
        throw SlackError.api(method: method, error: "ratelimited", needed: nil)
    }

    /// Follows next_cursor until it runs out.
    func pages<P: Decodable, T>(_ method: String, _ params: [String: String], _ type: P.Type, _ items: (P) -> [T]) async throws -> [T] {
        var out: [T] = []
        var cursor: String?
        repeat {
            var p = params
            if let cursor { p["cursor"] = cursor }
            let r = try await call(method, p, as: WithCursor<P>.self)
            out += items(r.page)
            cursor = r.meta.cursor
        } while cursor != nil
        return out
    }

    // MARK: methods

    public struct Auth: Codable { public var user_id: String; public var user: String?; public var team_id: String; public var team: String?; public var url: String? }
    public func authTest() async throws -> Auth { try await call("auth.test") }

    public func users() async throws -> [SlackUser] {
        struct R: Codable { var members: [SlackUser] }
        return try await pages("users.list", ["limit": "200"], R.self) { $0.members }
    }

    public func conversations() async throws -> [SlackConversation] {
        struct R: Codable { var channels: [SlackConversation] }
        return try await pages("users.conversations", ["types": "public_channel,private_channel,mpim,im", "exclude_archived": "true", "limit": "200"], R.self) { $0.channels }
    }

    public func info(_ channel: String) async throws -> SlackConversation {
        struct R: Codable { var channel: SlackConversation }
        return try await call("conversations.info", ["channel": channel], as: R.self).channel
    }

    public struct History: Codable { public var messages: [SlackMessage]; public var has_more: Bool? }

    /// Newest first, as Slack returns it. `oldest` is exclusive.
    public func history(_ channel: String, oldest: String? = nil, latest: String? = nil, limit: Int = 100) async throws -> History {
        var p = ["channel": channel, "limit": String(limit)]
        if let oldest { p["oldest"] = oldest }
        if let latest { p["latest"] = latest }
        return try await call("conversations.history", p)
    }

    public func replies(_ channel: String, ts: String) async throws -> [SlackMessage] {
        struct R: Codable { var messages: [SlackMessage] }
        return try await pages("conversations.replies", ["channel": channel, "ts": ts, "limit": "200"], R.self) { $0.messages }
    }

    public struct Search: Codable {
        public struct Paging: Codable { public var count: Int?; public var total: Int?; public var page: Int?; public var pages: Int? }
        public struct Messages: Codable { public var matches: [SearchMatch]; public var paging: Paging? }
        public var messages: Messages
    }

    public func search(_ query: String, page: Int = 1, count: Int = 40) async throws -> Search {
        try await call("search.messages", ["query": query, "page": String(page), "count": String(count), "sort": "timestamp", "sort_dir": "desc"])
    }
}
