import Foundation

/// One row of the @ / # popup.
public struct MentionCandidate: Equatable {
    public enum Kind: Equatable { case person, bot, group, special, channel }
    public var target: MentionTarget
    public var label: String          // shown and inserted without the sigil: "Mira Chen", "eng", "here"
    public var detail: String         // real name / handle / member count
    public var kind: Kind
    public var avatar: String?
    public var keys: [String]         // what prefix matching runs over, lowercased

    public init(target: MentionTarget, label: String, detail: String, kind: Kind, avatar: String? = nil, keys: [String]) {
        self.target = target; self.label = label; self.detail = detail; self.kind = kind; self.avatar = avatar
        self.keys = keys.map { $0.lowercased() }
    }

    public var id: String {
        switch target {
        case .user(let s), .group(let s), .channel(let s), .special(let s): return s
        }
    }
}

/// A1/A5: members of this conversation first, then recent DM partners, then
/// everyone. Within a tier: prefix of display name, real name, handle, then
/// a prefix of a later word, then fuzzy. @here/@channel/@everyone come last
/// unless their name is what's being typed.
public struct MentionSearch {
    private let all: [MentionCandidate]
    private let fuzzy: Fuzzy

    public init(_ candidates: [MentionCandidate]) {
        all = candidates
        fuzzy = Fuzzy(candidates.map { $0.keys.joined(separator: " ") })
    }

    public static func people(_ ps: [Person], groups: [UserGroup], me: String?) -> [MentionCandidate] {
        var out: [MentionCandidate] = ps.filter { !$0.deleted }.map { p in
            MentionCandidate(target: .user(p.id), label: p.label, detail: p.realName.isEmpty || p.realName == p.label ? "@\(p.handle)" : p.realName,
                             kind: p.isBot ? .bot : .person, avatar: p.image48, keys: [p.displayName, p.realName, p.handle])
        }
        out += groups.map { g in
            MentionCandidate(target: .group(g.id), label: g.handle, detail: "\(g.name) · \(g.users.count) members", kind: .group, keys: [g.handle, g.name])
        }
        out += [("here", "Notify everyone online"), ("channel", "Notify everyone in this channel"), ("everyone", "Notify the whole workspace")].map {
            MentionCandidate(target: .special($0.0), label: $0.0, detail: $0.1, kind: .special, keys: [$0.0])
        }
        return out
    }

    public static func channels(_ cs: [Conversation]) -> [MentionCandidate] {
        cs.filter { !$0.isDM }.map { c in
            MentionCandidate(target: .channel(c.id), label: c.name, detail: c.topic ?? "", kind: .channel, keys: [c.name])
        }
    }

    public func rank(_ q: String, members: Set<String>, recent: [String], limit: Int) -> [MentionCandidate] {
        let ql = q.lowercased()
        let recentRank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func tier(_ c: MentionCandidate) -> Int {
            if c.kind == .special { return c.keys.contains(where: { !ql.isEmpty && $0.hasPrefix(ql) }) ? 0 : 4 }
            if members.contains(c.id) { return 0 }
            if recentRank[c.id] != nil { return 1 }
            return 2
        }
        func match(_ c: MentionCandidate) -> Int {
            if ql.isEmpty { return 1 }
            for (k, key) in c.keys.enumerated() where key.hasPrefix(ql) { return 1000 - k * 10 }
            for key in c.keys where key.split(separator: " ").dropFirst().contains(where: { $0.hasPrefix(ql) }) { return 600 }
            return 0
        }
        var scored: [(Int, Int, Int, Int)] = []   // tier, -match, recent, index
        if ql.isEmpty {
            for (i, c) in all.enumerated() { scored.append((tier(c), 0, recentRank[c.id] ?? Int.max, i)) }
        } else {
            var seen = Set<Int>()
            for (i, c) in all.enumerated() {
                let m = match(c)
                if m > 0 { scored.append((tier(c), -m, recentRank[c.id] ?? Int.max, i)); seen.insert(i) }
            }
            if scored.count < limit {
                for (i, s) in fuzzy.rank(q, limit: limit * 2) where !seen.contains(i) { scored.append((tier(all[i]) + 5, -s, Int.max, i)) }
            }
        }
        scored.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 != b.1 ? a.1 < b.1 : a.2 != b.2 ? a.2 < b.2 : a.3 < b.3 }
        return scored.prefix(limit).map { all[$0.3] }
    }
}
