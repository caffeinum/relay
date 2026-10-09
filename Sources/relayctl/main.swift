import Foundation
import CoreGraphics
import RelayCore

// Raw access to the same objects the app uses, for agents and scripts.
// Never prints tokens.

let usage = """
usage: \(Brand.cli) [-w workspace] <command>
  init                    write a starter \(Paths.config.path)
  auth                    auth.test against the workspace
  sync                    pull people, conversations and new messages into the cache
  directory               refresh user groups and custom emoji now
  channels                conversations from the cache, unread first
  people                  people and bots from the cache
  history <#name|id> [n]  last n messages from the cache
  thread <#name|id> <ts>  fetch and print a thread
  search <words>          local fts search
  rsearch <words>         Slack's search.messages
  send <#c> <text> [--thread ts]   post through the outbox (no undo window)
  edit <#c> <ts> <text>   chat.update one of my messages through the outbox
  delete <#c> <ts>        chat.delete one of my messages through the outbox
  react <#c> <ts> <name>  toggle my reaction
  mark <#c> [ts]          conversations.mark (default: the newest message)
  outbox                  every outbox item
  drafts                  every draft, newest first
  draft <#c> [--thread ts] [text]  show, or save (empty text deletes)
  live                    connect (socket mode, else polling) and print events
  seed-bench [--force]    write a 100k-message db as workspace "bench"
  perf                    p50/p95 of the per-frame store reads (use -w bench)
  bench [n]               launch the app n times and report first-frame times
"""

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("\(Brand.cli): \(s)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var workspace: String?
if args.first == "-w" {
    guard args.count > 1 else { fail("-w needs a workspace") }
    workspace = args[1]
    args.removeFirst(2)
}
guard let cmd = args.first else { print(usage); exit(0) }
var rest = Array(args.dropFirst())

/// Pulls `--name value` out of rest.
func option(_ name: String) -> String? {
    guard let i = rest.firstIndex(of: name) else { return nil }
    guard i + 1 < rest.count else { fail("\(name) needs a value") }
    let v = rest[i + 1]
    rest.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    guard let i = rest.firstIndex(of: name) else { return false }
    rest.remove(at: i)
    return true
}

func open() throws -> (Store, Sync) {
    let config = try Config.load()
    let (name, _) = try config.current(workspace)
    try Paths.ensure()
    let store = try Store(path: Paths.database(name).path)
    return (store, Sync(store: store, slack: try Slack(config: config, workspace: name)))
}

func resolve(_ s: String, _ store: Store) throws -> Conversation {
    let all = try store.conversations()
    let key = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard let c = all.first(where: { $0.id == key || $0.name == key }) else { fail("no conversation \(s) in the cache; run sync") }
    return c
}

func cached(_ c: Conversation, _ ts: String, _ store: Store) throws -> Message {
    guard let m = try store.message(c.id, ts: ts) else { fail("no message \(ts) in \(c.label) in the cache; run sync") }
    return m
}

func time(_ ts: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: Double(ts) ?? 0))
}

func show(_ m: Message, _ store: Store, indent: String = "") {
    var tags: [String] = []
    if m.replyCount > 0 { tags.append("\(m.replyCount) replies") }
    if m.edited { tags.append("edited") }
    if m.isBot { tags.append("bot") }
    if !m.reactions.isEmpty { tags.append(m.reactions.map { ":\($0.name): \($0.count)" }.joined(separator: " ")) }
    if let l = m.local { tags.append("\(l.kind.rawValue) \(l.state.rawValue)" + (l.error.map { ": \($0)" } ?? "")) }
    let suffix = tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"
    print("\(indent)\(time(m.ts)) \(m.ts) \(m.author): \(Mrkdwn.plain(m.text, names: store.name(of:)))\(suffix)")
}

func main() async throws {
    switch cmd {
    case "init":
        if FileManager.default.fileExists(atPath: Paths.config.path) { fail("\(Paths.config.path) already exists") }
        try Config.starter.save()
        print(Paths.config.path)
    case "auth":
        let (_, sync) = try open()
        let a = try await sync.slack.authTest()
        print("ok user=\(a.user ?? a.user_id) (\(a.user_id)) team=\(a.team ?? a.team_id) url=\(a.url ?? "")")
    case "sync":
        let (store, sync) = try open()
        let t = Date()
        try await sync.all()
        print(String(format: "synced %d conversations, %d messages cached, %.1fs", try store.conversations().count, store.messageCount, Date().timeIntervalSince(t)))
    case "directory":
        let (store, sync) = try open()
        await sync.directory(force: true)
        print("usergroups: \(try store.usergroups().count)" + (store.get("usergroups.unavailable").map { " (unavailable: \($0))" } ?? ""))
        print("emoji: \(try store.customEmoji().count)" + (store.get("emoji.unavailable").map { " (unavailable: \($0))" } ?? ""))
    case "channels":
        let (store, _) = try open()
        for c in try store.conversations().sorted(by: { ($0.unread > 0 ? 1 : 0, $0.latest) > ($1.unread > 0 ? 1 : 0, $1.latest) }) {
            let marks = [c.hasDraft ? "draft" : nil, c.isSelf ? "self" : nil, c.userIsBot ? "bot" : nil].compactMap { $0 }
            print("\(c.id)\t\(c.kind.rawValue)\t\(c.unread)\t\(c.mentions)\t\(c.label)" + (marks.isEmpty ? "" : "\t[\(marks.joined(separator: ","))]"))
        }
    case "people":
        let (store, _) = try open()
        for p in try store.people() { print("\(p.id)\t@\(p.handle)\t\(p.label)" + (p.isBot ? "\tbot" : "") + (p.image48 != nil ? "\tavatar" : "")) }
    case "history":
        guard let name = rest.first else { fail("history needs a conversation") }
        let (store, _) = try open()
        let c = try resolve(name, store)
        for m in try store.messages(c.id, limit: rest.count > 1 ? Int(rest[1]) ?? 20 : 20) { show(m, store) }
    case "thread":
        guard rest.count == 2 else { fail("thread needs a conversation and a ts") }
        let (store, sync) = try open()
        let c = try resolve(rest[0], store)
        try await sync.thread(c.id, ts: rest[1])
        for m in try store.thread(c.id, ts: rest[1]) { show(m, store, indent: m.isThreadReply ? "    " : "") }
    case "search", "rsearch":
        guard !rest.isEmpty else { fail("\(cmd) needs words") }
        let (store, sync) = try open()
        let q = rest.joined(separator: " ")
        let hits = cmd == "search" ? try store.search(q) : try await sync.remoteSearch(q)
        for h in hits { print("\(time(h.ts)) \(h.channelName) \(h.author): \(Mrkdwn.plain(h.text, names: store.name(of:)))") }
    case "send", "edit", "delete", "react", "mark", "outbox", "drafts", "draft":
        try await writes(cmd)
    case "live":
        try await live()
    case "seed-bench":
        try seedBench(force: flag("--force"))
    case "perf":
        try perf()
    case "bench":
        try bench(Int(rest.first ?? "") ?? 5)
    default:
        print(usage)
        exit(2)
    }
}

do { try await main() } catch { fail("\(error)") }
