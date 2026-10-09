import Foundation
import RelayCore

/// The outbox, reactions, marks and drafts, each checkable from the shell.
/// With writes off every write prints Slack.writeBlocked and stores nothing.
func writes(_ cmd: String) async throws {
    let (store, sync) = try open()
    let outbox = Outbox(store: store, slack: sync.slack, undoSeconds: 3600)
    func deliver(_ item: OutboxItem) async throws {
        await outbox.fire(item.id)
        guard let done = try outbox.items(channel: item.channel).first(where: { $0.id == item.id }) else { fail("outbox item \(item.id) vanished") }
        guard done.state == .sent else { fail("\(item.kind.rawValue) \(done.state.rawValue): \(done.error ?? "no error recorded")") }
        print("\(item.kind.rawValue) ok \(done.targetTS ?? "")")
    }
    switch cmd {
    case "send":
        let thread = option("--thread")
        guard rest.count >= 2 else { fail("send needs a conversation and text") }
        let c = try resolve(rest[0], store)
        try await deliver(try outbox.send(channel: c.id, thread: thread, text: rest.dropFirst().joined(separator: " ")))
    case "edit":
        guard rest.count >= 3 else { fail("edit needs a conversation, a ts and text") }
        let c = try resolve(rest[0], store)
        try await deliver(try outbox.edit(try cached(c, rest[1], store), text: rest.dropFirst(2).joined(separator: " ")))
    case "delete":
        guard rest.count == 2 else { fail("delete needs a conversation and a ts") }
        let c = try resolve(rest[0], store)
        try await deliver(try outbox.delete(try cached(c, rest[1], store)))
    case "react":
        guard rest.count == 3 else { fail("react needs a conversation, a ts and an emoji name") }
        let c = try resolve(rest[0], store)
        let name = rest[2].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        try await sync.toggleReactionNow(try cached(c, rest[1], store), name)
        let after = try store.reactions(channel: c.id, ts: rest[1]) ?? []
        let remote = try await sync.slack.reactions(channel: c.id, ts: rest[1])
        print("local:  " + after.map { ":\($0.name): \($0.count) \($0.users ?? [])" }.joined(separator: " "))
        print("remote: " + remote.map { ":\($0.name): \($0.count) \($0.users ?? [])" }.joined(separator: " "))
    case "mark":
        guard let name = rest.first else { fail("mark needs a conversation") }
        let c = try resolve(name, store)
        let ts = rest.count > 1 ? rest[1] : c.latest
        try sync.slack.gate("conversations.mark")
        try await sync.markNow(c.id, ts: ts)
        print("marked \(c.label) at \(ts); unread now \(try store.conversation(c.id)?.unread ?? -1)")
    case "outbox":
        for i in try outbox.items() {
            print("\(i.id)\t\(i.kind.rawValue)\t\(i.state.rawValue)\t\(i.channel)\t\(i.targetTS ?? "-")\t\(i.text ?? "")" + (i.error.map { "\t\($0)" } ?? ""))
        }
    case "drafts":
        for d in try store.drafts() { print("\(d.channel)\(d.threadTS.map { "/\($0)" } ?? "")\t\(d.text)") }
    case "draft":
        let thread = option("--thread")
        guard let name = rest.first else { fail("draft needs a conversation") }
        let c = try resolve(name, store)
        if rest.count > 1 {
            let text = rest.dropFirst().joined(separator: " ")
            try store.saveDraft(Draft(channel: c.id, threadTS: thread, text: text, selection: NSRange(location: (text as NSString).length, length: 0)))
        }
        print(try store.draft(c.id, thread: thread)?.text ?? "(no draft)")
    default:
        fail("unknown write \(cmd)")
    }
}

/// Connects the way the app does and prints what arrives. Never prints the token.
func live() async throws {
    let config = try Config.load()
    let (name, w) = try config.current(workspace)
    let (store, sync) = try open()
    setvbuf(stdout, nil, _IOLBF, 0)
    let token = Config.appToken(name, w)
    print("app token: \(token == nil ? "none" : "present")")
    let live = Live(store: store, sync: sync, appToken: token)
    live.onStatus = { print("status: \($0)") }
    live.onEvent = { kind, channels in print("event: \(kind) \(channels.sorted().joined(separator: ","))") }
    live.onError = { print("error: \($0)") }
    live.onChange = { print("changed: \($0.sorted().joined(separator: ","))") }
    if let c = option("--watch") { live.watch(channel: try resolve(c, store).id, thread: nil) }
    live.start()
    while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
}
