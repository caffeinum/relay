import Foundation
import Testing
@testable import RelayCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// The envelope's payload, as Live hands it to the applier, and the ack Live sends.
private func open(_ name: String) throws -> (payload: Data, ack: [String: String], envelopeID: String) {
    let env = try fixture(name)
    let o = try #require(try JSONSerialization.jsonObject(with: env) as? [String: Any])
    let ack = try #require(try JSONSerialization.jsonObject(with: try EventApplier.ack(for: env)) as? [String: String])
    return (try JSONSerialization.data(withJSONObject: o["payload"]!), ack, o["envelope_id"] as! String)
}

private func apply(_ name: String, _ s: Store) throws -> Set<String> {
    let e = try open(name)
    #expect(e.ack == ["envelope_id": e.envelopeID])
    return try EventApplier.apply(e.payload, to: s)
}

@Test func newMessageLands() throws {
    let s = try seeded()
    #expect(try apply("message", s) == ["C1"])
    let m = try #require(try s.message("C1", ts: "150.000000"))
    #expect(m.author == "Mira Chen" && m.mentionsMe)
    #expect(try s.conversation("C1")?.latest == "150.000000")
}

@Test func replyBumpsItsParent() throws {
    let s = try seeded()
    #expect(try apply("message_reply", s) == ["C1"])
    let parent = try #require(try s.message("C1", ts: "100.000000"))
    #expect(parent.replyCount == 1 && parent.latestReply == "151.000000" && parent.replyUsers == ["U2"])
    #expect(try s.thread("C1", ts: "100.000000").map(\.ts) == ["100.000000", "151.000000"])
    #expect(try !s.messages("C1").contains { $0.ts == "151.000000" })
}

@Test func botMessageCarriesItsProfile() throws {
    let s = try seeded()
    _ = try apply("message_bot", s)
    let m = try #require(try s.message("C1", ts: "152.000000"))
    #expect(m.author == "deploybot" && m.isBot && m.avatar == "https://img/b.png" && m.user == "B1")
}

@Test func changedAndDeletedUpdateInPlace() throws {
    let s = try seeded()
    #expect(try apply("message_changed", s) == ["C1"])
    let m = try #require(try s.message("C1", ts: "102.000000"))
    #expect(m.text == "new, edited" && m.editedTS == "153.000000")
    #expect(try s.search("edited").map(\.ts) == ["102.000000"])
    #expect(try apply("message_deleted", s) == ["C1"])
    #expect(try s.message("C1", ts: "102.000000") == nil)
    #expect(try s.search("edited").isEmpty)
}

@Test func reactionsFromOthersAddAndRemove() throws {
    let s = try seeded()
    #expect(try apply("reaction_added", s) == ["C1"])
    #expect(try s.message("C1", ts: "101.000000")?.reactions == [SlackReaction(name: "eyes", count: 1, users: ["U2"])])
    #expect(try apply("reaction_removed", s) == ["C1"])
    #expect(try s.message("C1", ts: "101.000000")?.reactions == [])
}

@Test func markedEventsMoveTheCursor() throws {
    let s = try seeded()
    try s.put(conversations: [channel("C1", "eng", lastRead: "100.000000"), SlackConversation(id: "D2", is_im: true, user: "U2", last_read: "0")], me: "UME")
    try s.put(messages: [slackMsg("1.000000", "U2", "a"), slackMsg("2.000000", "U2", "b")], channel: "D2")
    #expect(try s.conversation("C1")?.unread == 1)
    #expect(try apply("channel_marked", s) == ["C1"])
    #expect(try s.conversation("C1")?.unread == 0)
    #expect(try apply("im_marked", s) == ["D2"])
    #expect(try s.conversation("D2")?.unread == 0)
}

@Test func directoryEvents() throws {
    let s = try seeded()
    #expect(try apply("member_joined_channel", s) == ["C1"])
    #expect(try s.members("C1") == ["U3"])
    #expect(try apply("user_change", s) == [])
    #expect(s.person("U2")?.label == "mira.c")
    #expect(s.person("U2")?.image48 == "https://img/m2.png")
    #expect(s.person("U2")?.tz == "Europe/Berlin")
    _ = try apply("emoji_changed", s)
    #expect(try s.customEmoji() == ["shipit": "https://emoji/shipit.png"])
    _ = try apply("subteam_updated", s)
    #expect(s.myGroups() == ["S1"])
}

@Test func repeatsAndUnknownEventsAreIgnored() throws {
    let s = try seeded()
    #expect(try apply("reaction_added", s) == ["C1"])
    #expect(try EventApplier.applied(try open("reaction_added").payload, to: s) == nil)
    #expect(try s.message("C1", ts: "101.000000")?.reactions.first?.count == 1)
    #expect(try EventApplier.applied(try open("unhandled").payload, to: s) == nil)
}

@Test func helloAndDisconnectHaveNoAck() throws {
    #expect(throws: LiveError.self) { try EventApplier.ack(for: try fixture("hello")) }
    #expect(throws: LiveError.self) { try EventApplier.ack(for: try fixture("disconnect")) }
}

@Test func malformedPayloadThrows() throws {
    let s = try seeded()
    #expect(throws: LiveError.self) { try EventApplier.apply(Data("{\"event\": {\"type\": \"message\"}}".utf8), to: s) }
    #expect(throws: LiveError.self) { try EventApplier.apply(Data("nope".utf8), to: s) }
}

@Test func applyStaysUnderTwoMilliseconds() throws {
    let s = try seeded()
    let payload = try open("message").payload
    let o = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
    var times: [Double] = []
    for i in 0..<200 {
        var p = o
        p["event_id"] = "EvT\(i)"
        var e = p["event"] as! [String: Any]
        e["ts"] = String(format: "%d.000000", 2000 + i)
        p["event"] = e
        let d = try JSONSerialization.data(withJSONObject: p)
        let t0 = DispatchTime.now()
        _ = try EventApplier.apply(d, to: s)
        times.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
    }
    let p50 = times.sorted()[times.count / 2]
    #expect(p50 < 2, "p50 \(p50)ms")
}

@Test func noAppTokenMeansPolling() async throws {
    let s = try seeded()
    let live = Live(store: s, sync: Sync(store: s, slack: FakeSlack().client(writes: false)), appToken: nil)
    let seen = Statuses()
    live.onStatus = { seen.add($0) }
    live.start()
    #expect(await eventually { seen.all.contains(.polling(reason: "no app token")) })
    live.stop()
}

private final class Statuses: @unchecked Sendable {
    private let lock = NSLock()
    private var s: [Live.Status] = []
    func add(_ x: Live.Status) { lock.withLock { s.append(x) } }
    var all: [Live.Status] { lock.withLock { s } }
}

@Test func socketErrorsLoseTheirURL() {
    let e = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [
        NSLocalizedDescriptionKey: "The network connection was lost.",
        NSURLErrorFailingURLStringErrorKey: "wss://wss-primary.slack.com/link/?ticket=secret-ticket&app_id=A1",
    ])
    let s = Live.describe(e)
    #expect(!s.contains("ticket"))
    #expect(s.contains("-1005"))
    #expect(s.contains("connection was lost"))
}
