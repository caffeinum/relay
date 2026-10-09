import Foundation
import Testing
@testable import RelayCore

private func tempStore() throws -> Store {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try Store(path: dir.appendingPathComponent("t.sqlite").path)
}

private func msg(_ ts: String, _ user: String, _ text: String, thread: String? = nil) -> SlackMessage {
    SlackMessage(ts: ts, user: user, text: text, thread_ts: thread)
}

private func conv(_ id: String, _ name: String, lastRead: String = "0") -> SlackConversation {
    SlackConversation(id: id, name: name, is_channel: true, last_read: lastRead)
}

@Test func unreadCountsSkipMineRepliesAndSeen() throws {
    let s = try tempStore()
    s.set("me", "UME")
    try s.put(conversations: [conv("C1", "eng", lastRead: "100.0")], me: "UME")
    try s.put(messages: [
        msg("099.0", "U2", "old"), msg("101.0", "U2", "new one"), msg("102.0", "UME", "mine"),
        msg("103.0", "U2", "a reply", thread: "101.0"), msg("104.0", "U2", "hey <@UME>"),
    ], channel: "C1")
    var c = try s.conversations()[0]
    #expect(c.unread == 2)
    #expect(c.mentions == 1)
    #expect(c.latest == "104.0")
    try s.markSeen("C1", "104.0")
    c = try s.conversations()[0]
    #expect(c.unread == 0)
}

@Test func threadsAndHistoryAreSeparate() throws {
    let s = try tempStore()
    try s.put(conversations: [conv("C1", "eng")], me: "UME")
    try s.put(messages: [msg("1.0", "U2", "root", thread: "1.0"), msg("2.0", "U3", "reply", thread: "1.0"), msg("3.0", "U2", "next")], channel: "C1")
    #expect(try s.messages("C1").map(\.ts) == ["1.0", "3.0"])
    #expect(try s.thread("C1", ts: "1.0").map(\.ts) == ["1.0", "2.0"])
}

@Test func searchFindsPrefixesAndFollowsEdits() throws {
    let s = try tempStore()
    try s.put(users: [SlackUser(id: "U2", name: "mira", real_name: "Mira Chen", profile: .init(display_name: "", real_name: ""))])
    try s.put(conversations: [conv("C1", "eng")], me: "UME")
    try s.put(messages: [msg("1.0", "U2", "the cold start regressed")], channel: "C1")
    #expect(try s.search("regr").map(\.ts) == ["1.0"])
    #expect(try s.search("regr")[0].author == "Mira Chen")
    try s.put(messages: [msg("1.0", "U2", "fixed now")], channel: "C1")
    #expect(try s.search("regr").isEmpty)
    #expect(try s.search("fixed").count == 1)
    try s.delete(channel: "C1", ts: "1.0")
    #expect(try s.search("fixed").isEmpty)
}

@Test func vanishedConversationsStopShowing() throws {
    let s = try tempStore()
    try s.put(conversations: [conv("C1", "eng"), conv("C2", "old")], me: "UME")
    try s.put(conversations: [conv("C1", "eng")], me: "UME")
    #expect(try s.conversations().map(\.id) == ["C1"])
}

@Test func inlineTokensOnlyForEmulators() throws {
    #expect(throws: ConfigError.self) { try Config.token("real", .init(api: "https://slack.com/api", token: "xoxp-x")) }
    #expect(try Config.token("emu", .init(api: "http://localhost:4003/api", token: "xoxp-emu")) == "xoxp-emu")
}

@Test func writesAreRefusedByDefault() async throws {
    let slack = Slack(api: "http://127.0.0.1:9/api", token: "t")
    await #expect(throws: SlackError.self) { let _: Envelope = try await slack.call("chat.postMessage", ["text": "hi"]) }
}
