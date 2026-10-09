import Foundation
import Testing
@testable import RelayCore

private func posted(_ c: Call, ts: String = "200.000000") -> [String: Any] {
    var m: [String: Any] = ["ts": ts, "user": "UME", "text": c.params["text"] ?? "", "type": "message"]
    if let t = c.params["thread_ts"] { m["thread_ts"] = t }
    return ["channel": c.params["channel"] ?? "", "ts": ts, "message": m]
}

private func isWriteBlocked(_ e: Error) -> Bool {
    if case SlackError.writeBlocked = e { return true }
    return false
}

@Test func writesOffSendNothing() async throws {
    let fake = FakeSlack()
    let slack = fake.client(writes: false)
    let s = try seeded()
    let outbox = Outbox(store: s, slack: slack, undoSeconds: 3600)
    let mine = try #require(try s.message("C1", ts: "101.000000"))
    #expect(performing: { try outbox.send(channel: "C1", thread: nil, text: "hi") }, throws: isWriteBlocked)
    #expect(performing: { try outbox.edit(mine, text: "x") }, throws: isWriteBlocked)
    #expect(performing: { try outbox.delete(mine) }, throws: isWriteBlocked)
    #expect(try outbox.items().isEmpty)
    let sync = Sync(store: s, slack: slack)
    #expect(performing: { try sync.toggleReaction(mine, "eyes") }, throws: isWriteBlocked)
    #expect(try s.message("C1", ts: "101.000000")?.reactions == [])
    for write in [
        { try await slack.post(channel: "C1", text: "x", thread: nil) as Any },
        { try await slack.update(channel: "C1", ts: "1", text: "x") as Any },
        { try await slack.delete(channel: "C1", ts: "1") as Any },
        { try await slack.react(channel: "C1", ts: "1", name: "eyes", add: true) as Any },
        { try await slack.react(channel: "C1", ts: "1", name: "eyes", add: false) as Any },
        { try await slack.mark(channel: "C1", ts: "1") as Any },
        { try await slack.openDM(users: ["U2"]) as Any },
    ] {
        await #expect(performing: { _ = try await write() }, throws: isWriteBlocked)
    }
    #expect(fake.calls.isEmpty)
}

@Test func sendGoesPendingSendingSent() async throws {
    let fake = FakeSlack { c in c.method == "chat.postMessage" ? posted(c) : [:] }
    let s = try seeded()
    try s.saveDraft(Draft(channel: "C1", threadTS: nil, text: "hello", selection: NSRange()))
    let outbox = Outbox(store: s, slack: fake.client(writes: true), undoSeconds: 3600)
    let item = try outbox.send(channel: "C1", thread: nil, text: "hello")
    #expect(item.state == .pending)
    #expect(try s.draft("C1", thread: nil) == nil)
    let echo = try #require(try s.messages("C1").last)
    #expect(echo.id == -item.id && echo.ts == item.localTS && echo.isMine && echo.text == "hello")
    #expect(echo.local?.state == .pending && echo.local?.sendsAt == item.sendsAt)
    await outbox.fire(item.id)
    #expect(fake.calls == [Call(method: "chat.postMessage", params: ["channel": "C1", "text": "hello"])])
    #expect(try outbox.items(channel: "C1").map(\.state) == [.sent])
    #expect(try outbox.items(channel: "C1").first?.targetTS == "200.000000")
    let ms = try s.messages("C1")
    #expect(ms.filter { $0.text == "hello" }.map(\.ts) == ["200.000000"])
    #expect(ms.allSatisfy { $0.local == nil })
    await outbox.fire(item.id)
    #expect(fake.calls.count == 1)
}

@Test func threadSendsEchoInTheThreadOnly() throws {
    let s = try seeded()
    let outbox = Outbox(store: s, slack: FakeSlack().client(writes: true), undoSeconds: 3600)
    try outbox.send(channel: "C1", thread: "100.000000", text: "reply")
    #expect(try s.thread("C1", ts: "100.000000").map(\.text) == ["old", "reply"])
    #expect(try !s.messages("C1").contains { $0.text == "reply" })
}

@Test func undoCancelsPendingAndNothingIsSent() async throws {
    let fake = FakeSlack { c in posted(c) }
    let s = try seeded()
    let outbox = Outbox(store: s, slack: fake.client(writes: true), undoSeconds: 3600)
    let item = try outbox.send(channel: "C1", thread: nil, text: "oops")
    guard case .undone(let undone) = try outbox.undo() else { Issue.record("not undone"); return }
    #expect(undone.id == item.id && undone.state == .cancelled && undone.text == "oops")
    await outbox.fire(item.id)
    #expect(fake.calls.isEmpty)
    #expect(try !s.messages("C1").contains { $0.text == "oops" })
    #expect(try outbox.undo() == .nothing)
}

@Test func undoAfterSendingIsTooLate() async throws {
    let fake = FakeSlack { c in posted(c) }
    let s = try seeded()
    let outbox = Outbox(store: s, slack: fake.client(writes: true), undoSeconds: 0)
    let item = try outbox.send(channel: "C1", thread: nil, text: "gone")
    await outbox.fire(item.id)
    guard case .tooLate(let late) = try outbox.undo() else { Issue.record("expected tooLate"); return }
    #expect(late.id == item.id && late.state == .sent)
}

@Test func timerSendsAtTheEndOfTheWindow() async throws {
    let fake = FakeSlack { c in posted(c) }
    let s = try seeded()
    let outbox = Outbox(store: s, slack: fake.client(writes: true), undoSeconds: 0.05)
    try outbox.send(channel: "C1", thread: nil, text: "soon")
    #expect(try await eventually { try outbox.items(channel: "C1").first?.state == .sent })
}

@Test func failureKeepsTheEchoWithSlacksError() async throws {
    let fake = FakeSlack { _ in ["ok": false, "error": "channel_not_found"] }
    let s = try seeded()
    let outbox = Outbox(store: s, slack: fake.client(writes: true), undoSeconds: 3600)
    let item = try outbox.send(channel: "C1", thread: nil, text: "lost")
    await outbox.fire(item.id)
    let echo = try #require(try s.messages("C1").last)
    #expect(echo.text == "lost" && echo.local?.state == .failed && echo.local?.error == "channel_not_found")
    try outbox.retry(item.id)
    #expect(try outbox.items(channel: "C1").first?.state == .pending)
    #expect(try s.messages("C1").last?.local?.error == nil)
    fake.handler = { c in posted(c) }
    await outbox.fire(item.id)
    #expect(try outbox.items(channel: "C1").first?.state == .sent)
}

@Test func discardDropsAFailedEcho() async throws {
    let fake = FakeSlack { _ in ["ok": false, "error": "not_in_channel"] }
    let s = try seeded()
    let outbox = Outbox(store: s, slack: fake.client(writes: true), undoSeconds: 3600)
    let item = try outbox.send(channel: "C1", thread: nil, text: "lost")
    #expect(throws: OutboxError.self) { try outbox.discard(item.id) }
    await outbox.fire(item.id)
    try outbox.discard(item.id)
    #expect(try outbox.items(channel: "C1").map(\.state) == [.cancelled])
    #expect(try !s.messages("C1").contains { $0.text == "lost" })
    #expect(throws: OutboxError.self) { try outbox.retry(item.id) }
}

@Test func resumeFailsWhatWasLeftAtQuit() throws {
    let s = try seeded()
    let outbox = Outbox(store: s, slack: FakeSlack().client(writes: true), undoSeconds: 3600)
    let a = try outbox.send(channel: "C1", thread: nil, text: "a")
    let b = try outbox.send(channel: "C1", thread: nil, text: "b")
    try s.db.run("UPDATE outbox SET state='sending' WHERE id=?", b.id)
    let next = Outbox(store: s, slack: FakeSlack().client(writes: true), undoSeconds: 3600)
    try next.resume()
    let items = try next.items(channel: "C1")
    #expect(items.map(\.id) == [a.id, b.id])
    #expect(items.allSatisfy { $0.state == .failed && $0.error == Outbox.quitError })
    #expect(try s.messages("C1").suffix(2).map { $0.local?.state } == [.failed, .failed])
}

@Test func echoBeforeReplyDoesNotDuplicate() async throws {
    let s = try seeded()
    let fake = FakeSlack { c in
        if c.method == "chat.postMessage" {
            let event: [String: Any] = ["type": "event_callback", "event_id": "Ev1", "event": [
                "type": "message", "channel": "C1", "user": "UME", "text": c.params["text"]!, "ts": "200.000000"]]
            _ = try! EventApplier.apply(try! JSONSerialization.data(withJSONObject: event), to: s)
            #expect(try! s.messages("C1").filter { $0.text == "race" }.map(\.ts) == ["200.000000"])
        }
        return posted(c)
    }
    let outbox = Outbox(store: s, slack: fake.client(writes: true), undoSeconds: 3600)
    let item = try outbox.send(channel: "C1", thread: nil, text: "race")
    await outbox.fire(item.id)
    #expect(try outbox.items(channel: "C1").map(\.state) == [.sent])
    #expect(try s.messages("C1").filter { $0.text == "race" }.map(\.ts) == ["200.000000"])
}

@Test func editShowsNewTextThenLandsOnSlack() async throws {
    let fake = FakeSlack { c in c.method == "chat.update" ? ["channel": "C1", "ts": c.params["ts"]!, "text": c.params["text"]!] : [:] }
    let s = try seeded()
    let outbox = Outbox(store: s, slack: fake.client(writes: true), undoSeconds: 3600)
    let mine = try #require(try s.message("C1", ts: "101.000000"))
    let item = try outbox.edit(mine, text: "mine, fixed")
    let echo = try #require(try s.message("C1", ts: "101.000000"))
    #expect(echo.text == "mine, fixed" && echo.edited && echo.local?.kind == .edit && echo.local?.original == "mine")
    await outbox.fire(item.id)
    #expect(fake.calls == [Call(method: "chat.update", params: ["channel": "C1", "ts": "101.000000", "text": "mine, fixed"])])
    let after = try #require(try s.message("C1", ts: "101.000000"))
    #expect(after.text == "mine, fixed" && after.edited && after.local == nil)
    #expect(try s.search("fixed").map(\.ts) == ["101.000000"])
}

@Test func undoAnEditRestoresTheOriginal() throws {
    let s = try seeded()
    let outbox = Outbox(store: s, slack: FakeSlack().client(writes: true), undoSeconds: 3600)
    try outbox.edit(try #require(try s.message("C1", ts: "101.000000")), text: "changed")
    _ = try outbox.undo()
    let m = try #require(try s.message("C1", ts: "101.000000"))
    #expect(m.text == "mine" && !m.edited && m.local == nil)
}

@Test func failedEditRestoresTheRow() async throws {
    let fake = FakeSlack { _ in ["ok": false, "error": "edit_window_closed"] }
    let s = try seeded()
    let outbox = Outbox(store: s, slack: fake.client(writes: true), undoSeconds: 3600)
    let item = try outbox.edit(try #require(try s.message("C1", ts: "101.000000")), text: "late")
    await outbox.fire(item.id)
    let m = try #require(try s.message("C1", ts: "101.000000"))
    #expect(m.local?.state == .failed && m.local?.error == "edit_window_closed")
    try outbox.discard(item.id)
    #expect(try s.message("C1", ts: "101.000000")?.text == "mine")
}

@Test func deleteCollapsesThenRemoves() async throws {
    let fake = FakeSlack()
    let s = try seeded()
    let outbox = Outbox(store: s, slack: fake.client(writes: true), undoSeconds: 3600)
    let item = try outbox.delete(try #require(try s.message("C1", ts: "101.000000")))
    #expect(try s.message("C1", ts: "101.000000")?.local?.kind == .delete)
    await outbox.fire(item.id)
    #expect(fake.methods == ["chat.delete"])
    #expect(try s.message("C1", ts: "101.000000") == nil)
}

@Test func onlyMyMessagesEditOrDelete() throws {
    let s = try seeded()
    let outbox = Outbox(store: s, slack: FakeSlack().client(writes: true), undoSeconds: 3600)
    let theirs = try #require(try s.message("C1", ts: "102.000000"))
    #expect(throws: OutboxError.self) { try outbox.edit(theirs, text: "x") }
    #expect(throws: OutboxError.self) { try outbox.delete(theirs) }
    #expect(try outbox.items().isEmpty)
}
