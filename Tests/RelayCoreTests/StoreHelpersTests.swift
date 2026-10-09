import Foundation
import Testing
@testable import RelayCore

// Shared by the CORE tests: a fresh store on disk, and a Slack whose
// requests go to an in-process handler keyed by its token, so tests can
// run in parallel.

func makeStore(_ path: String? = nil) throws -> Store {
    if let path { return try Store(path: path) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try Store(path: dir.appendingPathComponent("t.sqlite").path)
}

func tempPath() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("t.sqlite").path
}

struct Call: Equatable { var method: String; var params: [String: String] }

/// The handler answers one call with a JSON object (ok:true is added when missing).
final class FakeSlack: @unchecked Sendable {
    typealias Handler = (Call) -> [String: Any]
    let token = "xoxp-test-\(UUID().uuidString)"
    private let lock = NSLock()
    private var _calls: [Call] = []
    var handler: Handler

    init(_ handler: @escaping Handler = { _ in [:] }) {
        self.handler = handler
        FakeProtocol.register(self)
    }

    var calls: [Call] { lock.withLock { _calls } }
    var methods: [String] { calls.map(\.method) }

    func answer(_ c: Call) -> Data {
        lock.withLock { _calls.append(c) }
        var o = handler(c)
        if o["ok"] == nil { o["ok"] = true }
        return try! JSONSerialization.data(withJSONObject: o)
    }

    func client(writes: Bool) -> Slack {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeProtocol.self]
        return Slack(api: "http://fake.invalid/api", token: token, writes: writes, session: URLSession(configuration: config))
    }
}

final class FakeProtocol: URLProtocol {
    nonisolated(unsafe) private static var fakes: [String: FakeSlack] = [:]
    private static let lock = NSLock()

    static func register(_ f: FakeSlack) { lock.withLock { fakes["Bearer \(f.token)"] = f } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        guard let fake = Self.lock.withLock({ Self.fakes[auth] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
            s.close()
        }
        var c = URLComponents()
        c.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        let params = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let data = fake.answer(Call(method: request.url!.lastPathComponent, params: params))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

func slackMsg(_ ts: String, _ user: String?, _ text: String, thread: String? = nil, bot: String? = nil) -> SlackMessage {
    SlackMessage(ts: ts, user: user, bot_id: bot, text: text, thread_ts: thread)
}

func channel(_ id: String, _ name: String, lastRead: String = "0") -> SlackConversation {
    SlackConversation(id: id, name: name, is_channel: true, last_read: lastRead)
}

/// A store that knows me (UME), Mira (U2) and #eng (C1) with a few messages.
func seeded() throws -> Store {
    let s = try makeStore()
    try s.setValue("me", "UME")
    try s.put(users: [
        SlackUser(id: "UME", name: "aleks", real_name: "Aleks", profile: .init(display_name: "aleks")),
        SlackUser(id: "U2", name: "mira", real_name: "Mira Chen", profile: .init(display_name: "", real_name: "Mira Chen", image_48: "https://img/m.png")),
    ])
    try s.put(conversations: [channel("C1", "eng", lastRead: "100.000000")], me: "UME")
    try s.put(messages: [
        slackMsg("100.000000", "U2", "old"), slackMsg("101.000000", "UME", "mine"), slackMsg("102.000000", "U2", "new"),
    ], channel: "C1")
    return s
}

/// Waits for an async condition the outbox or sync reaches on another queue.
func eventually(_ timeout: TimeInterval = 2, _ check: () throws -> Bool) async rethrows -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if try check() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return try check()
}
