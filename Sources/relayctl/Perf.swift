import Foundation
import CoreGraphics
import RelayCore

let benchWorkspace = "bench"

func seedBench(force: Bool) throws {
    try Paths.ensure()
    let url = Paths.database(workspace ?? benchWorkspace)
    if FileManager.default.fileExists(atPath: url.path) {
        guard force else { fail("\(url.path) exists; pass --force to rebuild it") }
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
    let t = Date()
    let store = try Store(path: url.path)
    try BenchSeed.seed(store) { n in if n % 20 == 0 { print("seeded \(n) conversations") } }
    print(String(format: "%@: %d messages in %.1fs", url.path, store.messageCount, Date().timeIntervalSince(t)))
}

/// The reads one frame makes, on whatever db `-w` names (the bench one by default).
func perf() throws {
    let url = Paths.database(workspace ?? benchWorkspace)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("no db at \(url.path); run seed-bench") }
    let store = try Store(path: url.path)
    let convs = try store.conversations()
    guard !convs.isEmpty else { fail("\(url.path) has no conversations") }
    func measure(_ name: String, _ n: Int = 60, _ body: (Int) throws -> Void) rethrows {
        var times: [Double] = []
        for i in 0..<n {
            let t0 = DispatchTime.now()
            try body(i)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
        }
        times.sort()
        print(name.padding(toLength: 26, withPad: " ", startingAt: 0) + String(format: " p50 %6.2fms  p95 %6.2fms", times[n / 2], times[n * 95 / 100]))
    }
    print("\(store.messageCount) messages, \(convs.count) conversations")
    try measure("conversations()") { _ in _ = try store.conversations() }
    try measure("messages(c, 200)") { i in _ = try store.messages(convs[i % convs.count].id, limit: 200) }
    try measure("firstUnread(c)") { i in _ = try store.firstUnread(convs[i % convs.count].id) }
    try measure("messages + firstUnread") { i in
        let id = convs[(i * 7) % convs.count].id
        _ = try store.messages(id, limit: 200)
        _ = try store.firstUnread(id)
    }
    try measure("people()") { _ in _ = try store.people() }
    try measure("search(\"deploy green\")", 20) { _ in _ = try store.search("deploy green", limit: 50) }
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
