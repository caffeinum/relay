import Foundation

/// A synthetic workspace for `relayctl seed-bench` and `perf`: 100k
/// messages over 200 conversations by default, with threads, reactions,
/// mentions and mostly-read cursors, like a real cache after a few months.
public enum BenchSeed {
    public static let me = "UBENCH0"

    public static func seed(_ store: Store, conversations: Int = 200, perConversation: Int = 500, people: Int = 500,
                            progress: (Int) -> Void = { _ in }) throws {
        var rng = SplitMix(seed: 2027)
        try store.setValue("me", me)
        try store.setValue("team", "bench")
        try store.put(users: (0..<people).map { i in
            SlackUser(id: "UBENCH\(i)", name: "user\(i)", real_name: "User \(i)", deleted: false, is_bot: i % 50 == 49,
                      profile: .init(display_name: i % 3 == 0 ? "" : "u\(i)", real_name: "User \(i)"))
        })
        let convs: [SlackConversation] = (0..<conversations).map { i in
            if i % 10 == 9 { return SlackConversation(id: "DBENCH\(i)", is_im: true, user: "UBENCH\(i % people)") }
            return SlackConversation(id: "CBENCH\(i)", name: "channel-\(i)", is_channel: true)
        }
        try store.put(conversations: convs, me: me)
        let start = 1_700_000_000
        let words = ["build", "deploy", "green", "flaky", "review", "ship", "coffee", "standup", "cache", "frame", "sqlite", "thread"]
        for (ci, c) in convs.enumerated() {
            var ms: [SlackMessage] = []
            var lastTop = "0"
            for j in 0..<perConversation {
                let ts = String(format: "%d.%06d", start + ci * 1000 + j * 60, j)
                let user = j % 7 == 0 ? me : "UBENCH\(rng.next(people))"
                var text = (0..<(3 + rng.next(12))).map { _ in words[rng.next(words.count)] }.joined(separator: " ")
                if j % 40 == 0 { text += " <@\(me)>" }
                if j % 97 == 0 { text = "```\nlet x = \(j)\n```" }
                var m = SlackMessage(ts: ts, user: user, text: text)
                if j % 20 == 5, lastTop != "0" { m.thread_ts = lastTop } else { lastTop = ts }
                if j % 10 == 3 { m.reactions = [SlackReaction(name: "eyes", count: 2, users: [me, "UBENCH1"])] }
                if j % 25 == 0 { m.edited = .init(ts: ts) }
                ms.append(m)
            }
            try store.put(messages: ms, channel: c.id)
            let readAt = ci % 10 == 0 ? 0 : perConversation - 1 - (ci % 7) * 3
            try store.setLastRead(c.id, readAt <= 0 ? "0" : ms[readAt].ts)
            progress(ci + 1)
        }
    }
}

/// Deterministic, so every seeded db is the same.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ n: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(n))
    }
}
