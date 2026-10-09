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
    try s.setValue("me", "UME")
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
    let fake = FakeSlack()
    let slack = fake.client(writes: false)
    do {
        let _: Envelope = try await slack.call("chat.postMessage", ["text": "hi"])
        Issue.record("a write went through with writes off")
    } catch SlackError.writeBlocked(let m) {
        #expect(m == "chat.postMessage")
    }
    #expect(fake.calls.isEmpty, "no request may leave when writes are off")
    #expect(Config.starter.workspaces["2027dev"]?.writes != true, "the starter config keeps the real workspace read-only")
}

@Test func parentsWithoutLatestReplyTakeTheNewestCachedReply() throws {
    let s = try tempStore()
    try s.put(conversations: [conv("C1", "eng")], me: "UME")
    var root = msg("1.0", "U2", "root", thread: "1.0")
    root.reply_count = 2
    try s.put(messages: [root, msg("2.0", "U3", "a", thread: "1.0"), msg("3.0", "U3", "b", thread: "1.0")], channel: "C1")
    #expect(try s.messages("C1").first?.latestReply == "3.0")
}

@Test func unreadThreadsUseThreadReadElseTheChannelCursor() throws {
    let s = try tempStore()
    try s.put(conversations: [conv("C1", "eng", lastRead: "5.0")], me: "UME")
    try s.setUI(.threadRead("C1", "1.0"), "9.0")
    let roots = [(ts: "1.0", latest: "8.0"), (ts: "2.0", latest: "6.0"), (ts: "3.0", latest: "4.0"), (ts: "4.0", latest: "10.0")]
    try s.setUI(.threadRead("C1", "4.0"), "9.0")
    #expect(try s.unreadThreads("C1", roots: roots) == ["2.0", "4.0"])
    try s.setUI(.threadRead("C10", "2.0"), "99.0")
    #expect(try s.unreadThreads("C1", roots: roots) == ["2.0", "4.0"])
}

@Test func messagesSinceKeepsTheLoadedWindow() throws {
    let s = try tempStore()
    try s.put(conversations: [conv("C1", "eng")], me: "UME")
    try s.put(messages: (1...300).map { msg(String(format: "%d.000000", 1000 + $0), "U2", "m\($0)") }, channel: "C1")
    #expect(try s.messages("C1").count == 200)
    #expect(try s.messages("C1", since: "1051.000000").count == 250)
    #expect(try s.messages("C1", before: "1101.000000", limit: 200).map(\.ts).last == "1100.000000")
}

@Test func mainThreadReadsDontWaitForABackgroundWrite() async throws {
    let s = try tempStore()
    try s.put(conversations: [conv("C1", "eng")], me: "UME")
    try await MainActor.run { try s.db.openReader() }
    let started = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        try? s.db.transaction {
            try s.db.run("INSERT INTO kv(key,value) VALUES('held','1')")
            started.signal()
            Thread.sleep(forTimeInterval: 0.4)
        }
        done.signal()
    }
    started.wait()
    let ms = try await MainActor.run {
        let t0 = Date()
        _ = try s.conversations()
        #expect(try s.value("held") == nil, "an uncommitted write isn't visible to the reader")
        return Date().timeIntervalSince(t0) * 1000
    }
    #expect(ms < 200, "main read waited \(ms) ms")
    done.wait()
    let held = try await MainActor.run { try s.value("held") }
    #expect(held == "1")
}
