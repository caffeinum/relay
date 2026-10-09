import Foundation
import CoreGraphics
import ChatCore

// Raw access to the same objects the app uses, for agents and scripts.
// Never prints tokens.

let usage = """
usage: \(Brand.cli) [-w workspace] <command>
  init                    write a starter \(Paths.config.path)
  auth                    auth.test against the workspace
  sync                    pull people, conversations and new messages into the cache
  channels                conversations from the cache, unread first
  history <#name|id> [n]  last n messages from the cache
  thread <#name|id> <ts>  fetch and print a thread
  search <words>          local fts search
  rsearch <words>         Slack's search.messages
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
let rest = Array(args.dropFirst())

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

func time(_ ts: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: Double(ts) ?? 0))
}

func show(_ m: Message, _ store: Store, indent: String = "") {
    let thread = m.replyCount > 0 ? "  [\(m.replyCount) replies]" : ""
    print("\(indent)\(time(m.ts)) \(m.ts) \(m.author): \(Mrkdwn.plain(m.text, names: store.name(of:)))\(thread)")
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
    case "channels":
        let (store, _) = try open()
        for c in try store.conversations().sorted(by: { ($0.unread > 0 ? 1 : 0, $0.latest) > ($1.unread > 0 ? 1 : 0, $1.latest) }) {
            print("\(c.id)\t\(c.kind.rawValue)\t\(c.unread)\t\(c.label)")
        }
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
    case "bench":
        try bench(Int(rest.first ?? "") ?? 5)
    default:
        print(usage)
        exit(2)
    }
}

/// Cold start, two ways: the app's own report (kernel process start to
/// its first frame committed) and, seen from outside, spawn until the
/// window is on screen.
func bench(_ n: Int) throws {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("\(Brand.name).app/Contents/MacOS/\(Brand.name)")
    guard FileManager.default.isExecutableFile(atPath: exe.path) else { fail("no app at \(exe.path); run ./build.sh") }
    var seen: [Double] = [], reported: [Double] = []
    let prefix = Brand.slug.uppercased()
    for i in 0..<n {
        let p = Process()
        p.executableURL = exe
        var env = ProcessInfo.processInfo.environment
        env["\(prefix)_BENCH"] = "1"
        env["\(prefix)_BENCH_HOLD"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let t0 = DispatchTime.now()
        try p.run()
        let pid = p.processIdentifier
        var onscreen: Double?
        while p.isRunning, onscreen == nil {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            if info.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 200 }) {
                onscreen = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            }
            usleep(500)
        }
        p.waitUntilExit()
        let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let rep = line.split(separator: " ").first { $0.hasPrefix("first_frame_ms=") }.flatMap { Double($0.dropFirst(15)) }
        print(String(format: "run %d: on screen %.0fms, app reports %.0fms", i + 1, onscreen ?? -1, rep ?? -1))
        if let onscreen { seen.append(onscreen) }
        if let rep { reported.append(rep) }
        usleep(300_000)
    }
    func line(_ name: String, _ v: [Double]) {
        let s = v.sorted()
        guard !s.isEmpty else { print("\(name): no samples"); return }
        print(String(format: "%@: median %.0fms, min %.0fms, max %.0fms (n=%d)", name, s[s.count / 2], s[0], s[s.count - 1], s.count))
    }
    line("first frame (app)", reported)
    line("on screen (outside)", seen)
}

do { try await main() } catch { fail("\(error)") }
