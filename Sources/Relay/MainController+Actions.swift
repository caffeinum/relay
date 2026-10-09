import AppKit
import RelayCore

/// Message actions, sending, undo, reactions and read state.
extension MainController {
    func actions(for l: MessageList, inThread: Bool) -> MessageActions {
        var a = MessageActions()
        a.react = { [weak self] m in self?.pickReaction(for: m) }
        a.toggleReaction = { [weak self] m, name in self?.toggleReaction(m, name) }
        a.quickReactions = { [weak self] in self?.quickReactions() ?? ["+1", "eyes", "white_check_mark"] }
        a.reply = { [weak self] m in self?.openThread(ts: m.threadTS ?? m.ts, focus: true); self?.threadComposer.focus() }
        a.copyLink = { [weak self] m in self?.copyLink(m) }
        a.save = { [weak self] m in self?.toggleSaved(m) }
        a.edit = { [weak self, weak l] m in if let l { self?.edit(m, in: l) } }
        a.saveEdit = { [weak self] m, text in self?.saveEdit(m, text) }
        a.delete = { [weak self] m in self?.delete(m) }
        a.more = { [weak self, weak l] m in if let l { l.select(l.messages.firstIndex(of: m) ?? 0) }; self?.showPalette(query: "", only: "Message") }
        a.retry = { [weak self] m in self?.retry(m) }
        a.openThread = { [weak self] m in self?.openThread(ts: m.threadTS ?? m.ts, focus: true) }
        a.openUser = { [weak self] id, _ in self?.openDM(id) }
        a.openChannel = { [weak self] id in self?.open(id) }
        a.openURL = { [weak self] url, background in self?.openURL(url, background: background) }
        a.nearTop = { [weak self] in if !inThread { self?.loadOlder() } }
        a.bottomVisible = { [weak self, weak l] in if let l { self?.bottomVisible(l, inThread: inThread) } }
        a.markRead = { [weak self] in self?.markCurrentRead() }
        return a
    }

    // MARK: composer

    func configure(_ c: Composer, inThread: Bool) {
        c.readOnly = !writes
        c.complete = { [weak self] sigil, q in self?.suggestions(sigil, q) ?? [] }
        c.popupHost = root
        c.onSend = { [weak self, weak c] text in if let c { self?.send(text, from: c) } }
        c.onSaveDraft = { [weak self] d in self?.saveDraft(d) }
        c.onFocus = { [weak self] in self?.list.keyboardLeft(); self?.thread.keyboardLeft() }
        c.onEditLast = { [weak self] in self?.editLast(inThread: inThread) }
        c.onUndoEmpty = { [weak self] in self?.undo(); return true }
        c.onEscape = { [weak self, weak c] in
            guard let self, let c else { return }
            self.window.makeFirstResponder(nil)
            if inThread, c.isEmpty { self.closeThread() }
        }
    }

    func makeComposerTextView() -> ComposerTextView {
        let t = ComposerTextView()
        t.complete = { [weak self] sigil, q in self?.suggestions(sigil, q) ?? [] }
        t.popupHost = root
        return t
    }

    func decodeDraft(_ mrkdwn: String) -> (String, [MentionToken]) {
        let r = Mentions.decode(mrkdwn) { [weak self] t in self?.label(t) }
        return (r.text, r.tokens)
    }

    func label(_ t: MentionTarget) -> String? {
        switch t {
        case .user(let id): return store.person(id)?.label
        case .channel(let id): return (cached({ try store.conversation(id) }) ?? nil)?.name
        case .group(let id): return (cached({ try store.usergroups() }) ?? []).first { $0.id == id }?.handle
        case .special(let s): return s
        }
    }

    private func saveDraft(_ d: Draft) {
        do { try store.saveDraft(d) } catch { report(error, "draft"); return }
        let hadDraft = current?.hasDraft ?? false
        let hasNow = !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ((cached({ try store.draftThreads(d.channel) }) ?? []).isEmpty == false)
        if d.threadTS != nil, let id = current?.id, id == d.channel {
            list.draftThreads = cached({ try store.draftThreads(id) }) ?? []
        }
        if hadDraft != hasNow || d.channel != current?.id { reloadSidebar() } else { sidebar.draftCount = (cached({ try store.drafts() }) ?? []).count }
    }

    func send(_ text: String, from c: Composer) {
        guard let conv = current else { return }
        let thread = c.key.thread
        if let name = reactShortcut(text) {
            let target = thread == nil ? list.messages.last { $0.id > 0 } : self.thread.messages.last { $0.id > 0 }
            guard let target else { toast.show("Nothing to react to", error: true); return }
            toggleReaction(target, name)
            c.clear()
            do { try store.clearDraft(conv.id, thread: thread) } catch { report(error, "draft") }
            return
        }
        guard let outbox else { toast.show(syncProblem ?? "Not connected", error: true); return }
        do {
            try outbox.send(channel: conv.id, thread: thread, text: text)
        } catch {
            report(error, "send")
            return
        }
        c.clear()
        toast.undo(thread == nil ? "Sending" : "Sending reply", seconds: outbox.undoSeconds) { [weak self] in self?.undo() }
        cacheChanged([conv.id])
        (thread == nil ? list : self.thread).scrollToBottom()
    }

    /// R4: "+:eyes:" as the whole message reacts to the newest one.
    func reactShortcut(_ text: String) -> String? {
        guard text.hasPrefix("+:"), text.hasSuffix(":"), text.count > 3 else { return nil }
        let name = String(text.dropFirst(2).dropLast())
        guard !name.contains(" "), EmojiData.glyph(name) != nil || (list.context.customEmoji[name] != nil) else { return nil }
        return name
    }

    // MARK: edit, delete, undo

    func isMine(_ m: Message) -> Bool { m.isMine || (store.me != nil && m.user == store.me) }

    func edit(_ m: Message, in l: MessageList) {
        guard isMine(m) else { toast.show("You can only edit your own messages", error: true); return }
        guard m.local?.kind != .send else { toast.show("That message hasn't been sent yet: z to undo it", error: true); return }
        if let i = l.messages.firstIndex(where: { $0.ts == m.ts }) { l.select(i) }
        if !l.beginEdit(ts: m.ts) { toast.show("Couldn't edit: the message isn't on screen", error: true) }
    }

    func editLast(inThread: Bool) {
        let l = inThread ? thread : list
        guard let m = l.messages.last(where: { isMine($0) && $0.local?.kind != .send && !$0.isSystem }) else {
            toast.show("No message of yours here to edit")
            return
        }
        focusThread(inThread)
        edit(m, in: l)
    }

    func saveEdit(_ m: Message, _ text: String) {
        guard text != m.text else { return }
        guard let outbox else { toast.show(syncProblem ?? "Not connected", error: true); return }
        do { try outbox.edit(m, text: text) } catch { report(error, "edit"); return }
        toast.undo("Saving edit", seconds: outbox.undoSeconds) { [weak self] in self?.undo() }
        cacheChanged([m.channel])
    }

    func requestDelete(_ m: Message, in l: MessageList) {
        guard isMine(m) else { toast.show("You can only delete your own messages", error: true); return }
        l.confirmDelete(ts: m.ts)
    }

    func delete(_ m: Message) {
        guard let outbox else { toast.show(syncProblem ?? "Not connected", error: true); return }
        if m.local?.kind == .send, m.local?.state == .failed {
            do { try outbox.discard(m.local!.outbox) } catch { report(error, "discard") }
            return
        }
        do { try outbox.delete(m) } catch { report(error, "delete"); return }
        toast.undo(m.replyCount > 0 ? "Deleting (keeps \(m.replyCount) replies)" : "Deleting", seconds: outbox.undoSeconds) { [weak self] in self?.undo() }
        cacheChanged([m.channel])
    }

    func retry(_ m: Message) {
        guard let outbox, let l = m.local, l.state == .failed else { return }
        do { try outbox.retry(l.outbox) } catch { report(error, "retry"); return }
        toast.undo("Retrying", seconds: outbox.undoSeconds) { [weak self] in self?.undo() }
        cacheChanged([m.channel])
    }

    /// O2: the newest pending item comes back; a send's text returns to its composer.
    func undo() {
        guard let outbox else { toast.show(syncProblem ?? "Not connected", error: true); return }
        toast.dismissUndo()
        do {
            switch try outbox.undo() {
            case .undone(let item):
                if item.kind == .send, let text = item.text {
                    if let c = [composer, threadComposer].first(where: { $0.key.channel == item.channel && $0.key.thread == item.threadTS }) {
                        let merged = Draft.merge(c.mrkdwn, text)
                        let (t, tokens) = decodeDraft(merged)
                        c.put(t, tokens: tokens)
                        c.focus()
                    } else {
                        try store.appendDraft(channel: item.channel, thread: item.threadTS, text: text)
                    }
                }
                toast.show(item.kind == .send ? "Unsent" : item.kind == .edit ? "Edit undone" : "Delete undone", kind: .success)
                cacheChanged([item.channel])
            case .tooLate:
                toast.show("Too late to undo, already sent")
            case .nothing:
                toast.show("Nothing to undo")
            }
        } catch { report(error, "undo") }
    }

    // MARK: reactions

    func pickReaction(for m: Message) {
        let frequent = cachedUI(.frequentEmoji) ?? [:]
        let custom = list.context.customEmoji
        var s = Palette.Section(title: "Emoji", prefix: nil)
        s.cap = 40
        s.dynamic = { [weak self] q in
            let names = EmojiSearch.rank(q.isEmpty ? "" : q, frequent: frequent, custom: custom, limit: 40)
            let shown = names.isEmpty && q.isEmpty ? ["+1", "eyes", "white_check_mark", "heart", "joy", "tada", "pray", "fire"] : names
            return shown.map { name in
                let mine = m.reactions.first { $0.name == name }?.users?.contains(self?.store.me ?? "") ?? false
                return Palette.Item(icon: .text(EmojiData.glyph(name) ?? "▫︎"), title: ":\(name):", detail: mine ? "remove my reaction" : "",
                                    run: { self?.toggleReaction(m, name) })
            }
        }
        present(Palette(placeholder: "React with…", sections: [s]))
    }

    func toggleReaction(_ m: Message, _ name: String) {
        guard let sync else { toast.show(syncProblem ?? "Not connected", error: true); return }
        do { try sync.toggleReaction(m, name) } catch { report(error, "reaction"); return }
        var f = cachedUI(.frequentEmoji) ?? [:]
        f[name, default: 0] += 1
        setUI(.frequentEmoji, f)
    }

    func quickReactions() -> [String] {
        let f = cachedUI(.frequentEmoji) ?? [:]
        let top = f.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        return Array((top + ["+1", "eyes", "white_check_mark"]).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3))
    }

    // MARK: links, saved, DMs

    func slackURL(_ channel: String, ts: String? = nil) -> URL? {
        guard let base = store.get("url") else { return nil }
        var s = base.hasSuffix("/") ? base : base + "/"
        s += "archives/\(channel)"
        if let ts { s += "/p" + ts.replacingOccurrences(of: ".", with: "") }
        return URL(string: s)
    }

    func copyLink(_ m: Message) {
        guard let u = slackURL(m.channel, ts: m.ts) else { toast.show("No workspace URL cached yet: sync first", error: true); return }
        copy(u.absoluteString, "Link copied")
    }

    func copy(_ s: String, _ note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        toast.show(note, kind: .success)
    }

    func toggleSaved(_ m: Message) {
        var saved = cachedUI(.saved) ?? []
        let key = "\(m.channel)/\(m.ts)"
        if let i = saved.firstIndex(of: key) { saved.remove(at: i); toast.show("Removed from saved") } else { saved.insert(key, at: 0); toast.show("Saved for later", kind: .success) }
        setUI(.saved, saved)
    }

    func openURL(_ url: URL, background: Bool) {
        if url.scheme == "relay-channel" { open(url.absoluteString.replacingOccurrences(of: "relay-channel:", with: "")); return }
        if Launch.headless { log("headless: not opening \(url.absoluteString)"); toast.show("Would open \(url.host ?? url.absoluteString)"); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = !background
        NSWorkspace.shared.open(url, configuration: cfg) { [weak self] _, e in
            if let e { DispatchQueue.main.async { self?.report(e, "open \(url.absoluteString)") } }
        }
    }

    func openDM(_ user: String) {
        guard let sync else { toast.show(syncProblem ?? "Not connected", error: true); return }
        if let c = sidebar.allConversations.first(where: { $0.kind == .im && $0.userID == user }) { open(c.id); return }
        Task { @MainActor [weak self] in
            do { self?.open(try await sync.openDM(user)) } catch { self?.report(error, "open DM") }
        }
    }

    // MARK: read state

    private func bottomVisible(_ l: MessageList, inThread: Bool) {
        guard let c = current, let last = l.messages.last(where: { $0.id > 0 }) else { return }
        if inThread {
            guard let root = threadTS else { return }
            sync?.markThreadRead(c.id, thread: root, ts: last.ts)
            return
        }
        guard c.unread > 0 || ListLayout.tsLess(c.lastRead, last.ts) else { return }
        markRead(c.id, last.ts)
    }

    func markRead(_ channel: String, _ ts: String) {
        if let sync { sync.markRead(channel, ts: ts) } else {
            do { try store.markSeen(channel, ts) } catch { report(error, "mark read") }
            reloadSidebar()
        }
    }

    func markCurrentRead() {
        guard let c = current, let last = list.messages.last(where: { $0.id > 0 }) else { return }
        markRead(c.id, last.ts)
    }

    func markUnread(_ m: Message) {
        guard let sync, let c = current else { return }
        sync.markUnread(c.id, before: m.ts)
        toast.show("Marked unread from here")
    }

    func markAllRead() {
        if let sync { sync.markAllRead() } else {
            for c in sidebar.allConversations where c.unread > 0 { do { try store.markSeen(c.id, c.latest) } catch { report(error, "mark read"); return } }
            reloadSidebar()
        }
        toast.show("Everything marked read", kind: .success)
    }

    // MARK: autocomplete sources

    func buildMentionIndex() -> MentionSearch {
        MentionSearch(MentionSearch.people(cached({ try store.people() }) ?? [], groups: cached({ try store.usergroups() }) ?? [], me: store.me))
    }

    func suggestions(_ sigil: Character, _ q: String) -> [Suggestion] {
        switch sigil {
        case "@":
            if mentionIndexStale { mentionIndex = buildMentionIndex(); mentionIndexStale = false }
            let members = current.flatMap { c in cached({ try store.members(c.id) }) } ?? []
            let recent = sidebar.allConversations.filter { $0.kind == .im }.sorted { ListLayout.tsLess($1.latest, $0.latest) }.compactMap(\.userID)
            return mentionIndex.rank(q, members: members, recent: recent, limit: 8).map { c in
                let tag: String? = c.kind == .bot ? "APP" : c.kind == .group ? "GROUP" : nil
                let avatar: (String, String?)? = c.kind == .person || c.kind == .bot ? (c.id, c.avatar) : nil
                return Suggestion(title: c.kind == .special || c.kind == .group ? "@" + c.label : c.label, detail: c.detail, tag: tag,
                                  glyph: c.kind == .group || c.kind == .special ? "@" : nil, avatar: avatar, insert: .token(c.target, c.label))
            }
        case "#":
            let cs = MentionSearch(MentionSearch.channels(sidebar.allConversations))
            return cs.rank(q, members: [], recent: [], limit: 8).map { c in
                Suggestion(title: c.label, detail: c.detail, tag: nil, glyph: "#", avatar: nil, insert: .token(c.target, c.label))
            }
        case ":":
            let names = EmojiSearch.rank(q, frequent: cachedUI(.frequentEmoji) ?? [:], custom: list.context.customEmoji, limit: 8)
            return names.map { n in Suggestion(title: ":\(n):", detail: "", tag: nil, glyph: EmojiData.glyph(n) ?? "▫︎", avatar: nil, insert: .text(":\(n): ")) }
        default:
            return []
        }
    }
}
