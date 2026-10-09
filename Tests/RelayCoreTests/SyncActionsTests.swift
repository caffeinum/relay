import Foundation
import Testing
@testable import RelayCore

@Test func reactionIsOptimisticThenSent() async throws {
    let fake = FakeSlack()
    let s = try seeded()
    let sync = Sync(store: s, slack: fake.client(writes: true))
    let m = try #require(try s.message("C1", ts: "102.000000"))
    try await sync.toggleReactionNow(m, "eyes")
    #expect(fake.calls == [Call(method: "reactions.add", params: ["channel": "C1", "timestamp": "102.000000", "name": "eyes"])])
    let after = try #require(try s.message("C1", ts: "102.000000"))
    #expect(after.reactions == [SlackReaction(name: "eyes", count: 1, users: ["UME"])])
    try await sync.toggleReactionNow(after, "eyes")
    #expect(fake.methods.last == "reactions.remove")
    #expect(try s.message("C1", ts: "102.000000")?.reactions == [])
}

@Test func toggleReactionChangesTheStoreSynchronously() throws {
    let s = try seeded()
    let sync = Sync(store: s, slack: FakeSlack().client(writes: true))
    try sync.toggleReaction(try #require(try s.message("C1", ts: "102.000000")), "tada")
    #expect(try s.message("C1", ts: "102.000000")?.reactions.map(\.name) == ["tada"])
}

@Test func alreadyReactedReconcilesWithoutError() async throws {
    let fake = FakeSlack { c in
        switch c.method {
        case "reactions.add": return ["ok": false, "error": "already_reacted"]
        case "reactions.get": return ["type": "message", "message": ["ts": "102.000000", "reactions": [["name": "eyes", "count": 2, "users": ["U2", "UME"]]]]]
        default: return [:]
        }
    }
    let s = try seeded()
    let sync = Sync(store: s, slack: fake.client(writes: true))
    try await sync.toggleReactionNow(try #require(try s.message("C1", ts: "102.000000")), "eyes")
    #expect(fake.methods == ["reactions.add", "reactions.get"])
    #expect(try s.message("C1", ts: "102.000000")?.reactions == [SlackReaction(name: "eyes", count: 2, users: ["U2", "UME"])])
}

@Test func otherReactionErrorsRollBack() async throws {
    let fake = FakeSlack { _ in ["ok": false, "error": "too_many_reactions"] }
    let s = try seeded()
    let sync = Sync(store: s, slack: fake.client(writes: true))
    await #expect(throws: SlackError.self) { try await sync.toggleReactionNow(try #require(try s.message("C1", ts: "102.000000")), "eyes") }
    #expect(try s.message("C1", ts: "102.000000")?.reactions == [])
}

@Test func markThrottleCollapsesToOneTrailingCall() {
    let t = MarkThrottle()
    let t0 = Date(timeIntervalSince1970: 1000)
    #expect(t.request("C1", ts: "1", at: t0) == .now)
    #expect(t.request("C2", ts: "1", at: t0) == .now)
    #expect(t.request("C1", ts: "2", at: t0.addingTimeInterval(1)) == .later(2))
    #expect(t.request("C1", ts: "3", at: t0.addingTimeInterval(2)) == .merged)
    #expect(t.take("C1", at: t0.addingTimeInterval(3)) == "3")
    #expect(t.take("C1") == nil)
    #expect(t.request("C1", ts: "4", at: t0.addingTimeInterval(4)) == .later(2))
    #expect(t.request("C1", ts: "5", at: t0.addingTimeInterval(7)) == .merged)
}

@Test func markReadIsLocalWhenWritesAreOff() async throws {
    let fake = FakeSlack()
    let s = try seeded()
    let sync = Sync(store: s, slack: fake.client(writes: false))
    sync.markRead("C1", ts: "102.000000")
    #expect(try s.conversation("C1")?.unread == 0)
    sync.markUnread("C1", before: "102.000000")
    #expect(try s.conversation("C1")?.unread == 1)
    sync.markAllRead()
    #expect(try s.conversation("C1")?.unread == 0)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(fake.calls.isEmpty)
}

@Test func markReadCallsSlackOncePerWindow() async throws {
    let fake = FakeSlack()
    let s = try seeded()
    let sync = Sync(store: s, slack: fake.client(writes: true))
    sync.markRead("C1", ts: "101.000000")
    sync.markRead("C1", ts: "102.000000")
    #expect(try await eventually { fake.calls.count == 1 })
    #expect(fake.calls.first == Call(method: "conversations.mark", params: ["channel": "C1", "ts": "101.000000"]))
    #expect(try await eventually { try s.db.string("SELECT last_read FROM convs WHERE id='C1'") == "101.000000" })
}

@Test func threadReadNeverMovesBack() throws {
    let s = try seeded()
    let sync = Sync(store: s, slack: FakeSlack().client(writes: false))
    sync.markThreadRead("C1", thread: "100.000000", ts: "105.000000")
    sync.markThreadRead("C1", thread: "100.000000", ts: "103.000000")
    #expect(try s.ui(.threadRead("C1", "100.000000")) == "105.000000")
}

@Test func tsBeforeIsOneMicrosecondEarlier() {
    #expect(tsBefore("1728412345.000000") == "1728412344.999999")
    #expect(tsBefore("102.000010") == "102.000009")
    #expect(tsBefore("odd") == "odd")
}

@Test func openDMUsesTheCacheThenConversationsOpen() async throws {
    let fake = FakeSlack { c in c.method == "conversations.open" ? ["channel": ["id": "D9"]] : [:] }
    let s = try seeded()
    let sync = Sync(store: s, slack: fake.client(writes: true))
    #expect(try await sync.openDM("U2") == "D9")
    #expect(fake.calls == [Call(method: "conversations.open", params: ["users": "U2", "return_im": "true"])])
    #expect(try s.conversation("D9")?.userID == "U2")
    #expect(try await sync.openDM("U2") == "D9")
    #expect(fake.calls.count == 1)
}

@Test func missingDirectoryMethodsLeaveTablesEmptyAndSayWhy() async throws {
    let fake = FakeSlack { c in
        switch c.method {
        case "usergroups.list": return ["ok": false, "error": "unknown_method"]
        case "emoji.list": return ["emoji": ["party": "https://e/p.gif"]]
        default: return [:]
        }
    }
    let s = try seeded()
    let sync = Sync(store: s, slack: fake.client(writes: false))
    await sync.directory()
    #expect(try s.usergroups().isEmpty)
    #expect(s.get("usergroups.unavailable") == "usergroups.list: unknown_method")
    #expect(try s.customEmoji() == ["party": "https://e/p.gif"])
    #expect(s.get("emoji.unavailable") == nil)
    await sync.directory()
    #expect(fake.calls.count == 2)
}

@Test func unknownAuthorsAndMentionsAreFetchedOnce() async throws {
    let fake = FakeSlack { c in
        switch c.method {
        case "users.info": return ["user": ["id": c.params["user"]!, "name": "zed", "real_name": "Zed"]]
        case "bots.info": return ["bot": ["id": c.params["bot"]!, "name": "ci"]]
        default: return [:]
        }
    }
    let s = try seeded()
    let sync = Sync(store: s, slack: fake.client(writes: false))
    let ms = [slackMsg("130.000000", "U7", "hi <@U8> and <@U2>"), slackMsg("131.000000", nil, "built", bot: "B5")]
    try s.put(messages: ms, channel: "C1")
    await sync.resolve(ms, channel: "C1")
    #expect(Set(fake.calls.map { $0.params["user"] ?? $0.params["bot"] ?? "" }) == ["U7", "U8", "B5"])
    #expect(try s.message("C1", ts: "131.000000")?.author == "ci")
    #expect(try s.message("C1", ts: "130.000000")?.author == "Zed")
    await sync.resolve(ms, channel: "C1")
    #expect(fake.calls.count == 3)
}

@Test func unreachableConversationIsHiddenAndTheRestSync() async throws {
    let fake = FakeSlack { c in
        switch c.method {
        case "auth.test": return ["user_id": "UME", "team_id": "T1"]
        case "users.list": return ["members": []]
        case "users.conversations": return ["channels": [
            ["id": "C1", "name": "general", "is_channel": true],
            ["id": "D9", "is_im": true, "user": "USLACKBOT"],
        ]]
        case "conversations.info" where c.params["channel"] == "D9": return ["ok": false, "error": "channel_not_found"]
        case "conversations.info": return ["channel": ["id": "C1", "name": "general", "is_channel": true, "last_read": "100.000000"]]
        case "conversations.history": return ["messages": [["ts": "101.000000", "user": "UME", "text": "hi"]]]
        default: return [:]
        }
    }
    let s = try makeStore()
    try await Sync(store: s, slack: fake.client(writes: false)).all()
    #expect(try s.conversations().map(\.id) == ["C1"])
    #expect(try s.message("C1", ts: "101.000000")?.text == "hi")
    #expect(s.get("synced_at") != nil)
}

@Test func otherConversationFailuresSurfaceAfterTheRestSync() async throws {
    let fake = FakeSlack { c in
        switch c.method {
        case "auth.test": return ["user_id": "UME", "team_id": "T1"]
        case "users.list": return ["members": []]
        case "users.conversations": return ["channels": [
            ["id": "C1", "name": "general", "is_channel": true],
            ["id": "C2", "name": "broken", "is_channel": true],
        ]]
        case "conversations.info" where c.params["channel"] == "C2": return ["ok": false, "error": "internal_error"]
        case "conversations.info": return ["channel": ["id": "C1", "name": "general", "is_channel": true]]
        case "conversations.history": return ["messages": [["ts": "101.000000", "user": "UME", "text": "hi"]]]
        default: return [:]
        }
    }
    let s = try makeStore()
    await #expect(throws: SyncError.self) { try await Sync(store: s, slack: fake.client(writes: false)).all() }
    #expect(try s.message("C1", ts: "101.000000")?.text == "hi")
    #expect(try s.conversations().count == 2)
}
