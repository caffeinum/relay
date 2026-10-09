import Foundation

public struct SidebarGroup: Equatable {
    public enum Kind: Equatable { case starred, section, channels, directs }
    public var id: String
    public var name: String
    public var icon: String?
    public var kind: Kind
    public var collapsed: Bool
    /// What the sidebar draws: everything, or when collapsed only rows that
    /// are unread, selected or hold a draft.
    public var rows: [Conversation]
    public var hidden: Int
}

/// Where each conversation goes in the sidebar (S1–S3): Starred, then the
/// local sections in order, then Channels, then Direct messages. A
/// conversation shows once; the first group that claims it wins.
public enum Sections {
    public static let starredID = "starred", channelsID = "channels", directsID = "directs"

    public struct Placement: Equatable {
        public var groups: [SidebarGroup]
        /// Section entries that match nothing in the cache (for the log).
        public var missing: [String]
    }

    public static func place(_ convs: [Conversation], sections: [SectionState], starred: [String], collapsed: Set<String> = [],
                             current: String?, drafts: Set<String>) -> Placement {
        let byID = Dictionary(convs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byName = Dictionary(convs.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>()
        var missing: [String] = []
        var groups: [SidebarGroup] = []

        func resolve(_ entry: String) -> Conversation? {
            let e = entry.hasPrefix("#") ? String(entry.dropFirst()) : entry
            return byID[e] ?? byName[e.lowercased()]
        }
        func keep(_ c: Conversation) -> Bool { c.unread > 0 || c.mentions > 0 || c.id == current || drafts.contains(c.id) || c.hasDraft }
        func add(_ id: String, _ name: String, _ icon: String?, _ kind: SidebarGroup.Kind, _ cs: [Conversation], collapsed: Bool, sort: SectionState.Sort) {
            let fresh = cs.filter { used.insert($0.id).inserted }
            guard !fresh.isEmpty || kind == .section else { return }
            let sorted = order(fresh, sort)
            let shown = collapsed ? sorted.filter(keep) : sorted
            groups.append(SidebarGroup(id: id, name: name, icon: icon, kind: kind, collapsed: collapsed, rows: shown, hidden: sorted.count - shown.count))
        }

        let stars = starred.compactMap { s -> Conversation? in
            guard let c = resolve(s) else { missing.append(s); return nil }
            return c
        }
        add(starredID, "Starred", "star", .starred, stars, collapsed: collapsed.contains(starredID), sort: .recent)
        for s in sections {
            let cs = s.channels.compactMap { e -> Conversation? in
                guard let c = resolve(e) else { missing.append(e); return nil }
                return c
            }
            add(s.id, s.name, s.icon, .section, cs, collapsed: s.collapsed, sort: s.sort)
        }
        add(channelsID, "Channels", nil, .channels, convs.filter { !$0.isDM }, collapsed: collapsed.contains(channelsID), sort: .recent)
        add(directsID, "Direct messages", nil, .directs, convs.filter(\.isDM), collapsed: collapsed.contains(directsID), sort: .recent)
        return Placement(groups: groups, missing: missing)
    }

    /// recent: unread first, then newest activity (C1). alpha: by name.
    static func order(_ cs: [Conversation], _ sort: SectionState.Sort) -> [Conversation] {
        switch sort {
        case .alpha:
            return cs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent:
            return cs.sorted { a, b in
                let ua = a.unread > 0 || a.mentions > 0, ub = b.unread > 0 || b.mentions > 0
                if ua != ub { return ua }
                if a.latest != b.latest { return ListLayout.tsLess(b.latest, a.latest) }
                return a.name < b.name
            }
        }
    }

    /// The sections seeded once from config (plan §0: kv is the source after that).
    public static func seed(_ config: [Config.Section]) -> [SectionState] {
        config.enumerated().map { i, s in SectionState(id: "s\(i)-\(s.name.lowercased())", name: s.name, channels: s.channels, sort: .recent) }
    }

    /// Moves `channel` into section `to` (nil: back to Channels / DMs), out of every other section.
    public static func move(_ channel: String, to: String?, in sections: [SectionState], aliases: Set<String> = []) -> [SectionState] {
        let names = aliases.union([channel])
        return sections.map { s in
            var s = s
            s.channels.removeAll { names.contains($0.hasPrefix("#") ? String($0.dropFirst()) : $0) || names.contains($0) }
            if s.id == to { s.channels.append(channel) }
            return s
        }
    }
}
