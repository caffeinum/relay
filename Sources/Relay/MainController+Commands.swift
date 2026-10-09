import AppKit
import RelayCore

/// Keys → `Commands` → `run`. ⌘K is built from the same table.
extension MainController {
    // MARK: keys

    func key(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags
        guard let name = Commands.keyName(chars: e.charactersIgnoringModifiers ?? "", keyCode: e.keyCode, control: f.contains(.control),
                                          option: f.contains(.option), shift: f.contains(.shift), command: f.contains(.command)) else { return false }
        if let overlay {
            if name == "⌘K" { dismissOverlay(); return true }
            return overlay.handle(e)
        }
        if focusedList.handleConfirmKey(e) || list.handleConfirmKey(e) || thread.handleConfirmKey(e) { return true }
        let editing = window.isEditingText
        if let p = pendingKey {
            pendingKey = nil
            if !editing, let c = Commands.command(for: "\(p) \(name)") { run(c.id); return true }
            return !editing
        }
        if !editing, Commands.startsSequence(name) { pendingKey = name; return true }
        guard let c = Commands.command(for: name) else { return false }
        let chord = f.contains(.command) || f.contains(.control)
        if editing && (c.scope != .global || !chord) { return false }
        if c.scope == .message, focusedList.selectedMessage == nil { return false }
        run(c.id)
        return true
    }

    // MARK: commands

    func run(_ id: CommandID) {
        let l = focusedList
        let m = l.selectedMessage
        switch id {
        case .cursorDown: l.step(1)
        case .cursorUp: l.step(-1)
        case .top: l.selectFirst()
        case .bottom: l.selectLast(); l.scrollToBottom()
        case .reply: if let m { openThread(ts: m.threadTS ?? m.ts, focus: true); threadComposer.focus() }
        case .edit: if let m { edit(m, in: l) }
        case .delete: if let m { requestDelete(m, in: l) }
        case .react: if let m { pickReaction(for: m) }
        case .quick1, .quick2, .quick3:
            let q = quickReactions()
            let i = id == .quick1 ? 0 : id == .quick2 ? 1 : 2
            if let m, q.indices.contains(i) { toggleReaction(m, q[i]) }
        case .undo: undo()
        case .copyLink: if let m { copyLink(m) }
        case .copyText: if let m { copy(Mrkdwn.plain(m.text, names: store.name(of:)), "Text copied") }
        case .save: if let m { toggleSaved(m) }
        case .markUnread: if let m { markUnread(m) }
        case .openInSlack:
            guard let c = current, let u = slackURL(c.id, ts: m?.ts) else { toast.show("No workspace URL cached yet: sync first", error: true); return }
            openURL(u, background: false)
        case .focusComposer:
            if let m, let local = m.local, local.state == .failed { retry(m); return }
            focusedComposer.focus()
        case .toggleFocus: if threadTS != nil { focusThread(!threadFocused) }
        case .escape:
            if threadFocused { focusThread(false) } else if threadTS != nil { closeThread() } else { markCurrentRead() }
        case .jumpUnreads: jumpToUnread()
        case .nextUnread, .prevUnread:
            if let c = sidebar.neighbour(id == .nextUnread ? 1 : -1, unreadOnly: true) { open(c.id) } else { toast.show("No more unreads") }
        case .nextConversation, .prevConversation:
            if let c = sidebar.neighbour(id == .nextConversation ? 1 : -1) { open(c.id) }
        case .jumpToNew: list.jumpToUnread()
        case .nextMention: l.jumpToNextMention()
        case .markAllRead: confirmMarkAllRead()
        case .search: showSearch()
        case .palette: showPalette()
        case .findConversation:
            if sidebar.isHidden { run(.toggleSidebar) }
            sidebar.focusFind()
        case .refresh: refresh()
        case .toggleSidebar:
            let show = sidebar.isHidden
            sidebar.isHidden = !show
            sidebarWidth.constant = show ? Sidebar.width : 0
            topBar.sidebarWidth = sidebarWidth.constant
            setUI(.sidebarVisible, show)
        case .toggleThread: if threadTS != nil { closeThread() } else { openThread() }
        case .closeThread: closeThread()
        case .threads: showThreads()
        case .drafts: showDrafts()
        case .editLast: editLast(inThread: threadFocused)
        case .star:
            guard let c = current else { return }
            if let i = starred.firstIndex(of: c.id) { starred.remove(at: i) } else { starred.insert(c.id, at: 0) }
            setUI(.starred, starred)
            header.starred = starred.contains(c.id)
            reloadSidebar()
        case .moveToSection: showPalette(query: "> move")
        case .newSection: askText("New section name") { [weak self] name in self?.newSection(name) }
        case .renameSection: showPalette(query: "> rename section")
        case .deleteSection: showPalette(query: "> delete section")
        case .collapseSection: showPalette(query: "> collapse")
        case .collapseAll:
            for i in sections.indices { sections[i].collapsed = true }
            collapsedGroups = [Sections.starredID, Sections.channelsID, Sections.directsID]
            setUI(.sections, sections)
            setUI(.collapsedGroups, collapsedGroups.sorted())
            reloadSidebar()
        case .copyChannelLink:
            guard let c = current, let u = slackURL(c.id) else { toast.show("No workspace URL cached yet: sync first", error: true); return }
            copy(u.absoluteString, "Channel link copied")
        case .back:
            guard let prev = history.popLast() else { return }
            if let c = current { future.append(c.id) }
            open(prev, recordHistory: false)
        case .forward:
            guard let next = future.popLast() else { return }
            if let c = current { history.append(c.id) }
            open(next, recordHistory: false)
        case .toggleAppearance:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            NSApp.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        case .toggleSeconds:
            let on = !(config.showSeconds ?? false)
            guard updateConfig({ $0.showSeconds = on }) else { return }
            TimeLabel.seconds = on
            list.redrawAll()
            thread.redrawAll()
            toast.show(on ? "Timestamps show seconds" : "Timestamps without seconds", kind: .success)
        case .undoWindow:
            let next: Double = (config.undoSeconds ?? Config.defaultUndoSeconds) == 10 ? 5 : 10
            guard updateConfig({ $0.undoSeconds = next }) else { return }
            outbox?.undoSeconds = next
            toast.show(String(format: "Undo window: %.0f s", next), kind: .success)
        case .switchWorkspace: showPalette(query: "> workspace")
        case .openLog: openFile(Paths.log)
        case .openConfig: openFile(Paths.config)
        case .revealDatabase:
            if Launch.headless { toast.show("Would reveal \(Paths.database(workspace).path)"); return }
            NSWorkspace.shared.activateFileViewerSelecting([Paths.database(workspace)])
        case .quit: NSApp.terminate(nil)
        }
    }

    /// K-3 toggles write config.json atomically; a failure says so and changes nothing.
    private func updateConfig(_ change: (inout Config) -> Void) -> Bool {
        do { config = try Config.update(change); return true } catch { report(error, "config"); return false }
    }

    private func openFile(_ u: URL) {
        if Launch.headless { log("headless: not opening \(u.path)"); toast.show("Would open \(u.lastPathComponent)"); return }
        NSWorkspace.shared.open(u)
    }

    // MARK: overlays

    func present(_ o: Overlay) {
        overlay?.removeFromSuperview()
        overlay = o
        list.dismissBar()
        thread.dismissBar()
        o.onClose = { [weak self] in self?.dismissOverlay() }
        o.show(in: root)
        if let p = o as? Palette { p.focus() } else if let p = o as? PickerOverlay { p.focus() }
    }

    func dismissOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
        window.makeFirstResponder(nil)
    }

    func showSearch(scope: Conversation? = nil) {
        let o = SearchOverlay(store: store, sync: sync)
        o.onHit = { [weak self] h in self?.open(h.channel, at: h.ts) }
        present(o)
        if let scope { o.field.stringValue = "in:\(scope.label) "; o.queryChanged(o.field.stringValue) }
    }

    private func confirmMarkAllRead() {
        let n = sidebar.allConversations.filter { $0.unread > 0 || $0.mentions > 0 }.count
        guard n > 0 else { toast.show("All caught up", kind: .success); return }
        var s = Palette.Section(title: "Mark all read?", prefix: nil)
        s.dynamic = { [weak self] _ in [Palette.Item(icon: .symbol("checkmark.circle"), title: "Mark \(n) conversation\(n == 1 ? "" : "s") read", detail: "↩ to confirm, esc to cancel", run: { self?.markAllRead() })] }
        present(Palette(placeholder: "Mark all read?", sections: [s]))
    }

    /// A one-field prompt in the palette card.
    func askText(_ prompt: String, initial: String = "", done: @escaping (String) -> Void) {
        var s = Palette.Section(title: prompt, prefix: nil)
        s.dynamic = { q in
            let t = q.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return [] }
            return [Palette.Item(icon: .symbol("return"), title: "“\(t)”", detail: prompt, run: { done(t) })]
        }
        present(Palette(placeholder: prompt, sections: [s], query: initial))
    }

    private func newSection(_ name: String) {
        var s = SectionState(id: "s\(Int(Date().timeIntervalSince1970))-\(name.lowercased())", name: name, channels: [], sort: .recent)
        if let c = current, !c.isDM { s.channels = [c.id]; sections = Sections.move(c.id, to: nil, in: sections, aliases: [c.name]) }
        sections.append(s)
        setUI(.sections, sections)
        reloadSidebar()
        toast.show("Section \(name) created", kind: .success)
    }

    func moveCurrent(to section: String?) {
        guard let c = current else { return }
        sections = Sections.move(c.id, to: section, in: sections, aliases: [c.name])
        if section == nil, let i = starred.firstIndex(of: c.id) { starred.remove(at: i); setUI(.starred, starred); header.starred = false }
        setUI(.sections, sections)
        reloadSidebar()
    }

    func sectionMenu(_ g: SidebarGroup, in v: NSView, at p: NSPoint) {
        guard g.kind == .section, let i = sections.firstIndex(where: { $0.id == g.id }) else { toggleCollapsed(g.id); return }
        let menu = NSMenu()
        let rename = MenuAction("Rename…") { [weak self] in self?.askText("Rename \(g.name)", initial: g.name) { self?.renameSection(g.id, $0) } }
        let sort = MenuAction(sections[i].sort == .alpha ? "Sort by recent" : "Sort A→Z") { [weak self] in
            guard let self, let j = self.sections.firstIndex(where: { $0.id == g.id }) else { return }
            self.sections[j].sort = self.sections[j].sort == .alpha ? .recent : .alpha
            self.setUI(.sections, self.sections)
            self.reloadSidebar()
        }
        let del = MenuAction("Delete section") { [weak self] in self?.deleteSection(g.id) }
        for a in [rename, sort, del] { menu.addItem(a.item) }
        menuActions = [rename, sort, del]
        menu.popUp(positioning: nil, at: p, in: v)
    }

    func headerMenu(at r: NSRect) {
        guard let c = current else { return }
        let details = MenuAction("Channel details") { [weak self] in self?.showPalette(query: "> channel details") }
        let link = MenuAction("Copy link") { [weak self] in self?.run(.copyChannelLink) }
        let slack = MenuAction("Open in Slack") { [weak self] in self?.run(.openInSlack) }
        let star = MenuAction(starred.contains(c.id) ? "Unstar \(c.label)" : "Star \(c.label)") { [weak self] in self?.run(.star) }
        let menu = NSMenu()
        for a in [details, link, slack, star] { menu.addItem(a.item) }
        menuActions = [details, link, slack, star]
        menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY), in: header)
    }

    func renameSection(_ id: String, _ name: String) {
        guard let i = sections.firstIndex(where: { $0.id == id }) else { return }
        sections[i].name = name
        setUI(.sections, sections)
        reloadSidebar()
    }

    func moveSection(_ id: String, by d: Int) {
        sections = Sections.reorder(sections, id, by: d)
        setUI(.sections, sections)
        reloadSidebar()
    }

    func deleteSection(_ id: String) {
        sections.removeAll { $0.id == id }
        setUI(.sections, sections)
        reloadSidebar()
    }

    // MARK: lists in the palette card

    func showDrafts() {
        let drafts = cached({ try store.drafts() }) ?? []
        let convs = Dictionary(sidebar.allConversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = drafts.map { d -> Palette.Item in
            let label = convs[d.channel]?.label ?? d.channel
            return Palette.Item(icon: .symbol("pencil"), title: d.threadTS == nil ? label : "Thread in \(label)",
                                detail: Mrkdwn.plain(d.text, names: store.name(of:), channels: { convs[$0]?.name },
                                                    groups: { [list] in list.context.groupHandle($0) }).replacingOccurrences(of: "\n", with: " "),
                                run: { [weak self] in self?.openDraft(d) })
        }
        var s = Palette.Section(title: "Drafts", prefix: nil, items: items, emptyQuery: items, cap: 50)
        if items.isEmpty { s.dynamic = { _ in [Palette.Item(icon: .none, title: "No drafts", run: {})] } }
        present(Palette(placeholder: "Drafts", sections: [s]))
    }

    func openDraft(_ d: Draft) {
        if current?.id != d.channel { open(d.channel) }
        if let t = d.threadTS { openThread(ts: t, focus: true); threadComposer.focus() } else { composer.focus() }
    }

    func showThreads() {
        let ts = cached({ try store.threads() }) ?? []
        let convs = Dictionary(sidebar.allConversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = ts.map { t -> Palette.Item in
            let m = t.message
            return Palette.Item(icon: .symbol("bubble.left.and.text.bubble.right"), title: "\(m.author): " + Mrkdwn.plain(m.text, names: store.name(of:)).replacingOccurrences(of: "\n", with: " "),
                                detail: "\(convs[m.channel]?.label ?? m.channel) · \(m.replyCount) replies", bold: t.unread,
                                run: { [weak self] in self?.open(m.channel, at: m.ts); self?.openThread(ts: m.ts, focus: true) })
        }
        var s = Palette.Section(title: "Threads", prefix: nil, items: items, emptyQuery: items, cap: 50)
        if items.isEmpty { s.dynamic = { _ in [Palette.Item(icon: .none, title: "No threads you're in yet", run: {})] } }
        present(Palette(placeholder: "Threads", sections: [s]))
    }

    func showMentions() {
        let ms = cached({ try store.mentionsOfMe() }) ?? []
        let convs = Dictionary(sidebar.allConversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = ms.map { m in
            Palette.Item(icon: .avatar(id: m.botID ?? m.user, name: m.author, url: m.avatar),
                         title: Mrkdwn.plain(m.text, names: store.name(of:)).replacingOccurrences(of: "\n", with: " "),
                         detail: "\(convs[m.channel]?.label ?? m.channel) · \(m.author) · \(TimeLabel.short(m.date))",
                         run: { [weak self] in self?.open(m.channel, at: m.threadTS ?? m.ts) })
        }
        var s = Palette.Section(title: "Mentions", prefix: nil, items: items, emptyQuery: items, cap: 50)
        if items.isEmpty { s.dynamic = { _ in [Palette.Item(icon: .none, title: "No mentions in the cache", run: {})] } }
        present(Palette(placeholder: "Mentions", sections: [s]))
    }

    // MARK: ⌘K

    func showPalette(query: String = "", only: String? = nil) {
        let t0 = CACurrentMediaTime()
        var secs = paletteSections()
        if let only { secs = secs.filter { $0.title == only } }
        let p = Palette(placeholder: "Search conversations, people, commands, links…", sections: secs, query: query)
        present(p)
        log(String(format: "palette open %.1fms", (CACurrentMediaTime() - t0) * 1000))
    }

    func paletteSections() -> [Palette.Section] {
        let convs = sidebar.allConversations
        let byID = Dictionary(convs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func convItem(_ c: Conversation) -> Palette.Item {
            let icon: Palette.Icon = c.kind == .im ? .avatar(id: c.userID ?? c.id, name: c.name, url: c.userID.flatMap { store.person($0)?.image48 })
                : c.kind == .mpim ? .symbol("person.2.fill") : .text(c.kind == .private ? "⚿" : "#")
            let detail = c.isDM ? (c.isSelf ? "you" : "direct message") : (c.topic ?? "channel")
            return Palette.Item(icon: icon, title: c.kind == .channel || c.kind == .private ? c.name : c.name, detail: detail,
                                bold: c.unread > 0, badge: c.mentions, run: { [weak self] in self?.open(c.id) }, match: c.name)
        }
        var out: [Palette.Section] = []

        var url = Palette.Section(title: "Open", prefix: nil)
        url.dynamic = { [weak self] q in
            guard let u = Self.typedURL(q) else { return [] }
            return [Palette.Item(icon: .symbol("safari"), title: "Open \(u.absoluteString)", run: { self?.openURL(u, background: false) },
                                 alt: { self?.copy(u.absoluteString, "Link copied") })]
        }
        out.append(url)

        let recents = (cachedUI(.recents) ?? []).compactMap { byID[$0] }
        let unread = convs.filter { $0.unread > 0 && !recents.prefix(6).contains($0) }
        out.append(Palette.Section(title: "Conversations", prefix: "#", items: convs.map(convItem), emptyQuery: (Array(recents.prefix(6)) + unread.prefix(4)).map(convItem), cap: 5))

        let people = cached({ try store.people() }) ?? []
        out.append(Palette.Section(title: "People", prefix: "@", items: people.map { p in
            Palette.Item(icon: .avatar(id: p.id, name: p.label, url: p.image48), title: p.label,
                         detail: (p.isBot ? "APP · " : "") + "@\(p.handle)" + (p.title.map { " · \($0)" } ?? ""),
                         run: { [weak self] in self?.openDM(p.id) },
                         alt: { [weak self] in self?.insertMention(p) },
                         match: "\(p.label) \(p.realName) \(p.handle)")
        }, cap: 5))

        if let m = focusedList.selectedMessage {
            let mine = isMine(m)
            let msgCmds: [CommandID] = [.reply, .react, .quick1] + (mine ? [.edit, .delete] : []) + [.copyText, .copyLink, .openInSlack, .markUnread, .save]
            let items = msgCmds.compactMap { id -> Palette.Item? in
                guard let c = Commands.byID[id] else { return nil }
                let title = id == .quick1 ? "React :\(quickReactions()[0]):" : c.title
                return Palette.Item(icon: .symbol(c.symbol), title: title, detail: "\(m.author): " + Mrkdwn.plain(m.text, names: store.name(of:)).prefix(60),
                                    keys: c.keys.prefix(1).map { $0 }, run: { [weak self] in self?.run(id) }, match: title)
            }
            out.append(Palette.Section(title: "Message", prefix: nil, items: items, emptyQuery: items, cap: 4))
        }

        var cmds: [Palette.Item] = Commands.all.filter { $0.scope != .message && ![.palette, .moveToSection, .switchWorkspace, .renameSection, .deleteSection, .collapseSection].contains($0.id) }.map { c in
            var title = c.title
            if c.id == .star, let cur = current { title = starred.contains(cur.id) ? "Unstar \(cur.label)" : "Star \(cur.label)" }
            if c.id == .toggleSeconds, TimeLabel.seconds { title += "  ✓" }
            if c.id == .undoWindow { title = String(format: "Undo window: 5 s / 10 s (now %.0f s)", outbox?.undoSeconds ?? config.undoSeconds ?? Config.defaultUndoSeconds) }
            return Palette.Item(icon: .symbol(c.symbol), title: title, keys: c.keys.prefix(1).map { $0 }, run: { [weak self] in self?.run(c.id) }, match: title + " " + c.keys.joined(separator: " "))
        }
        if let c = current {
            for s in sections where !s.channels.contains(c.id) && !s.channels.contains(c.name) && !s.channels.contains("#" + c.name) {
                cmds.append(Palette.Item(icon: .symbol("folder"), title: "Move \(c.label) to \(s.name)", run: { [weak self] in self?.moveCurrent(to: s.id) }))
            }
            if sections.contains(where: { $0.channels.contains(c.id) || $0.channels.contains(c.name) || $0.channels.contains("#" + c.name) }) || starred.contains(c.id) {
                cmds.append(Palette.Item(icon: .symbol("folder"), title: "Move \(c.label) back to \(c.isDM ? "Direct messages" : "Channels")", run: { [weak self] in self?.moveCurrent(to: nil) }))
            }
            cmds.append(Palette.Item(icon: .symbol("info.circle"), title: "Channel details: \(c.label)",
                                     detail: [c.topic, (cached({ try store.members(c.id) }) ?? []).count.counted("member")].compactMap { $0 }.joined(separator: " · "),
                                     run: { [weak self] in self?.run(.copyChannelLink) }))
        }
        for s in sections {
            cmds.append(Palette.Item(icon: .symbol("chevron.right"), title: "\(s.collapsed ? "Expand" : "Collapse") section \(s.name)", run: { [weak self] in self?.toggleCollapsed(s.id) }))
            cmds.append(Palette.Item(icon: .symbol("character.cursor.ibeam"), title: "Rename section \(s.name)…", run: { [weak self] in
                DispatchQueue.main.async { self?.askText("Rename \(s.name)", initial: s.name) { self?.renameSection(s.id, $0) } }
            }))
            cmds.append(Palette.Item(icon: .symbol("folder.badge.minus"), title: "Delete section \(s.name)", run: { [weak self] in self?.deleteSection(s.id) }))
            cmds.append(Palette.Item(icon: .symbol("arrow.up"), title: "Move section \(s.name) up", run: { [weak self] in self?.moveSection(s.id, by: -1) }))
            cmds.append(Palette.Item(icon: .symbol("arrow.down"), title: "Move section \(s.name) down", run: { [weak self] in self?.moveSection(s.id, by: 1) }))
        }
        for name in config.workspaces.keys.sorted() where name != workspace {
            cmds.append(Palette.Item(icon: .symbol("building.2"), title: "Switch to workspace \(name)", run: { [weak self] in self?.onSwitchWorkspace?(name) }))
        }
        cmds.append(Palette.Item(icon: .symbol("dot.radiowaves.left.and.right"), title: "Live status: \(liveStatus ?? (live == nil ? "offline" : "live"))", run: {}))
        out.append(Palette.Section(title: "Commands", prefix: ">", items: cmds, emptyQuery: cmds, cap: 6))

        let links = (list.visibleLinks + thread.visibleLinks).reduce(into: [LinkRef]()) { acc, l in if !acc.contains(where: { $0.url == l.url }) { acc.append(l) } }
        let linkItems = links.map { l in
            Palette.Item(icon: .symbol("link"), title: l.label, detail: "\(l.url.host ?? "") · \(l.author)", run: { [weak self] in self?.openURL(l.url, background: false) },
                         alt: { [weak self] in self?.copy(l.url.absoluteString, "Link copied") }, match: "\(l.label) \(l.url.absoluteString)")
        }
        out.append(Palette.Section(title: "Links", prefix: nil, items: linkItems, emptyQuery: Array(linkItems.prefix(5)), cap: 5))

        var emoji = Palette.Section(title: "React", prefix: ":")
        emoji.dynamic = { [weak self] q in
            guard let self, !q.isEmpty, let m = self.focusedList.selectedMessage else { return [] }
            return EmojiSearch.rank(q, frequent: self.cachedUI(.frequentEmoji) ?? [:], custom: self.list.context.customEmoji, limit: 8).map { n in
                Palette.Item(icon: .text(EmojiData.glyph(n) ?? "▫︎"), title: ":\(n):", detail: "react to \(m.author)'s message", run: { [weak self] in self?.toggleReaction(m, n) })
            }
        }
        out.append(emoji)

        var search = Palette.Section(title: "Search", prefix: nil)
        search.dynamic = { [weak self] q in
            guard q.count >= 2 else { return [] }
            return [Palette.Item(icon: .symbol("magnifyingglass"), title: "Search messages for “\(q)”", keys: ["/"], run: {
                guard let self else { return }
                DispatchQueue.main.async { self.showSearch(); (self.overlay as? SearchOverlay).map { $0.field.stringValue = q; $0.queryChanged(q) } }
            })]
        }
        out.append(search)

        var messages = Palette.Section(title: "Messages", prefix: "/")
        let db = self.store
        messages.slow = { q, done in
            DispatchQueue.global(qos: .userInitiated).async {
                let hits: [Hit]
                do { hits = try db.search(q, limit: 5) } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.report(error, "palette search")
                        done([Palette.Item(icon: .symbol("exclamationmark.triangle"), title: "Search failed: \(error)", run: {})])
                    }
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    done(hits.map { h in
                        Palette.Item(icon: .symbol("text.bubble"), title: Mrkdwn.plain(h.text, names: db.name(of:)).replacingOccurrences(of: "\n", with: " "),
                                     detail: "\(h.channelName) · \(h.author) · \(TimeLabel.short(Date(timeIntervalSince1970: Double(h.ts) ?? 0)))",
                                     run: { self?.open(h.channel, at: h.ts) })
                    })
                }
            }
        }
        out.append(messages)
        return out
    }

    static func typedURL(_ q: String) -> URL? {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) }
        let host = t.split(separator: "/").first.map(String.init) ?? t
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return URL(string: "https://" + t)
    }

    func insertMention(_ p: Person) {
        let c = focusedComposer
        c.focus()
        let tv = c.textView
        let label = "@" + p.label
        let a = NSMutableAttributedString(string: label, attributes: [.font: Theme.Font.bodyMedium, .foregroundColor: Theme.mentionFg, .backgroundColor: Theme.mentionBg])
        a.addAttribute(.relayMention, value: MentionAttr(.user(p.id), label), range: NSRange(location: 0, length: a.length))
        a.append(NSAttributedString(string: " ", attributes: ComposerTextView.base))
        let r = tv.selectedRange()
        if tv.shouldChangeText(in: r, replacementString: a.string) {
            tv.textStorage?.replaceCharacters(in: r, with: a)
            tv.setSelectedRange(NSRange(location: r.location + a.length, length: 0))
            tv.didChangeText()
        }
    }
}

/// An NSMenuItem whose action is a closure.
final class MenuAction: NSObject {
    let item: NSMenuItem
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        super.init()
        item.target = self
        item.action = #selector(fire)
    }
    @objc private func fire() { run() }
}
