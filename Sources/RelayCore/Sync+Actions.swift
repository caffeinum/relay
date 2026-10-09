import Foundation

/// The ts just before `ts`: a read cursor there leaves `ts` unread.
func tsBefore(_ ts: String) -> String {
    let parts = ts.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let s = Int(parts[0]), let us = Int(parts[1]), parts[1].count == 6 else { return ts }
    let total = s * 1_000_000 + us - 1
    return String(format: "%d.%06d", total / 1_000_000, total % 1_000_000)
}

/// What happens at once in the store and then goes to Slack: reactions,
/// read cursors, opening a DM.
extension Sync {
    // MARK: reactions

    /// Flips my reaction in the store now, then calls Slack. Throws
    /// writeBlocked synchronously. A failure reverts, then onError;
    /// already_reacted/no_reaction reconcile with reactions.get, no error.
    public func toggleReaction(_ m: Message, _ name: String) throws {
        let add = try beginReaction(m, name)
        Task {
            do { try await finishReaction(m, name, add: add) } catch { report(error, "reaction \(name) on \(m.channel)/\(m.ts)") }
        }
    }

    /// The same, awaited: for relayctl and tests.
    public func toggleReactionNow(_ m: Message, _ name: String) async throws {
        try await finishReaction(m, name, add: try beginReaction(m, name))
    }

    private func beginReaction(_ m: Message, _ name: String) throws -> Bool {
        guard let me = store.me else { throw SyncError.notSignedIn }
        guard m.local?.kind != .send, m.id > 0 else { throw SyncError.notCached(channel: m.channel, ts: m.ts) }
        let current = try store.reactions(channel: m.channel, ts: m.ts) ?? m.reactions
        let add = !(current.first { $0.name == name }?.users?.contains(me) ?? false)
        try slack.gate(add ? "reactions.add" : "reactions.remove")
        try store.applyReaction(channel: m.channel, ts: m.ts, name: name, user: me, add: add)
        changed([m.channel])
        return add
    }

    private func finishReaction(_ m: Message, _ name: String, add: Bool) async throws {
        do {
            try await slack.react(channel: m.channel, ts: m.ts, name: name, add: add)
        } catch let e as SlackError where e.code == "already_reacted" || e.code == "no_reaction" {
            try store.setReactions(channel: m.channel, ts: m.ts, try await slack.reactions(channel: m.channel, ts: m.ts))
            changed([m.channel])
        } catch {
            if let me = store.me { try store.applyReaction(channel: m.channel, ts: m.ts, name: name, user: me, add: !add) }
            changed([m.channel])
            throw error
        }
    }

    // MARK: read cursors

    /// Local seen now; conversations.mark at most once per channel per 3 s
    /// when writes are on.
    public func markRead(_ channel: String, ts: String) {
        do { try store.markSeen(channel, ts) } catch { report(error, "markSeen \(channel)"); return }
        changed([channel])
        guard slack.writes else { return }
        switch marks.request(channel, ts: ts) {
        case .now: Task { await remoteMark(channel, ts) }
        case .later(let after):
            DispatchQueue.global().asyncAfter(deadline: .now() + after) { [self] in
                guard let ts = marks.take(channel) else { return }
                Task { await remoteMark(channel, ts) }
            }
        case .merged: break
        }
    }

    /// Awaited conversations.mark, also moving the local cursor (either way).
    public func markNow(_ channel: String, ts: String) async throws {
        try await slack.mark(channel: channel, ts: ts)
        try store.setLastRead(channel, ts)
        changed([channel])
    }

    private func remoteMark(_ channel: String, _ ts: String) async {
        do {
            try await slack.mark(channel: channel, ts: ts)
            try store.advanceLastRead(channel, ts)
        } catch { report(error, "conversations.mark \(channel)") }
    }

    /// Local only (UIKey.threadRead); never moves back.
    public func markThreadRead(_ channel: String, thread: String, ts: String) {
        do {
            let key = UIKey<String>.threadRead(channel, thread)
            if let cur = try store.ui(key), cur >= ts { return }
            try store.setUI(key, ts)
            changed([channel])
        } catch { report(error, "markThreadRead \(channel)/\(thread)") }
    }

    /// `ts` and everything after it is unread again; Slack's cursor follows when writes are on.
    public func markUnread(_ channel: String, before ts: String) {
        let cursor: String
        do { cursor = try store.markUnread(channel, from: ts) } catch { report(error, "markUnread \(channel)"); return }
        changed([channel])
        guard slack.writes else { return }
        Task {
            do { try await slack.mark(channel: channel, ts: cursor) } catch { report(error, "conversations.mark \(channel)") }
        }
    }

    /// Everything read locally now; with writes on, one conversations.mark
    /// per conversation, paced under Tier 3.
    public func markAllRead() {
        let unread: [Conversation]
        do {
            unread = try store.conversations().filter { $0.unread > 0 || $0.mentions > 0 }
            for c in unread { try store.markSeen(c.id, c.latest) }
        } catch { report(error, "markAllRead"); return }
        changed([])
        guard slack.writes, !unread.isEmpty else { return }
        Task {
            for c in unread {
                await remoteMark(c.id, c.latest)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    // MARK: DMs and members

    /// The cached im with `user`, else conversations.open (then cached).
    public func openDM(_ user: String) async throws -> String {
        if let c = try store.conversations().first(where: { $0.kind == .im && $0.userID == user }) { return c.id }
        var c = try await slack.openDM(users: [user])
        c.is_im = true
        if c.user == nil { c.user = user }
        try store.upsert(conversation: c)
        changed([])
        return c.id
    }

    /// Fire and forget: refreshes the member list when it's over a day old.
    public func members(_ channel: String) {
        do {
            if let at = try store.membersFetched(channel), Date().timeIntervalSince(at) < Self.day { return }
        } catch { report(error, "members \(channel)"); return }
        Task {
            do {
                try store.put(members: try await slack.members(channel), channel: channel)
                changed([])
            } catch { report(error, "conversations.members \(channel)") }
        }
    }
}
