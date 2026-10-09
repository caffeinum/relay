import AppKit
import RelayCore

extension UIKey where T == [String] {
    static let collapsedGroups = UIKey<[String]>("ui:collapsedGroups")
}

/// One window: the top bar, the sidebar, the channel (header, list,
/// composer) and a thread pane. Everything on screen before the first
/// frame comes from sqlite; the network starts after.
final class MainController: NSObject, NSWindowDelegate {
    let config: Config
    let workspace: String
    let store: Store
    let sync: Sync?
    let outbox: Outbox?
    private(set) var live: Live?
    private let appToken: () -> String?
    let writes: Bool
    let syncProblem: String?

    let window: KeyWindow
    let topBar = TopBar()
    let sidebar = Sidebar()
    let header = ChannelHeader()
    let list = MessageList()
    let composer = Composer()
    let threadHeader = ChannelHeader()
    let thread = MessageList()
    let threadComposer = Composer()
    let toast = Toast()
    let root = FlippedView()
    let mainPane = FlippedView()
    let threadPane = FlippedView()
    var sidebarWidth: NSLayoutConstraint!
    var threadWidth: NSLayoutConstraint!
    var menuActions: [MenuAction] = []

    var current: Conversation?
    var threadTS: String?
    var threadFocused = false
    var overlay: Overlay?
    var pendingKey: String?
    var loadingOlder = false
    var lastRefresh = Date.distantPast
    var history: [String] = [], future: [String] = []
    var sections: [SectionState] = []
    var starred: [String] = []
    var collapsedGroups: Set<String> = []
    var lastStatus: String?
    var liveStatus: String?
    var onSwitchWorkspace: ((String) -> Void)?
    lazy var mentionIndex: MentionSearch = buildMentionIndex()
    var mentionIndexStale = true

    init(config: Config, workspace: String, store: Store, sync: Sync?, appToken: @escaping () -> String?, syncProblem: String?) {
        self.config = config
        self.workspace = workspace
        self.store = store
        self.sync = sync
        self.writes = sync?.slack.writes ?? false
        self.outbox = sync.map { Outbox(store: store, slack: $0.slack) }
        self.appToken = appToken
        self.syncProblem = syncProblem
        window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        super.init()
        Launch.mark("window")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = Brand.name
        window.minSize = NSSize(width: 760, height: 420)
        let autosave = "\(Brand.name)Main"
        window.setFrameAutosaveName(autosave)
        if !window.setFrameUsingName(autosave) { window.center() }
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.backgroundColor = Theme.bg
        window.router = { [weak self] e in self?.key(e) ?? false }
        layout()
        Launch.mark("layout")
        wire()
    }

    private func layout() {
        window.contentView = root
        root.wantsLayer = true
        let line = NSView(), line2 = NSView()
        for l in [line, line2] { l.wantsLayer = true }
        line.layer?.backgroundColor = Theme.paneDivider.cgColor
        line2.layer?.backgroundColor = Theme.border.cgColor
        for v in [topBar, sidebar, line, mainPane, threadPane] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        for v in [header, list, composer, toast] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; mainPane.addSubview(v) }
        for v in [line2, threadHeader, thread, threadComposer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; threadPane.addSubview(v) }
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: Sidebar.width)
        threadWidth = threadPane.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor), topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor), topBar.heightAnchor.constraint(equalToConstant: TopBar.height),
            sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebarWidth,
            line.topAnchor.constraint(equalTo: topBar.bottomAnchor), line.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), line.widthAnchor.constraint(equalToConstant: 1),
            mainPane.topAnchor.constraint(equalTo: topBar.bottomAnchor), mainPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            mainPane.leadingAnchor.constraint(equalTo: line.trailingAnchor), mainPane.trailingAnchor.constraint(equalTo: threadPane.leadingAnchor),
            threadPane.topAnchor.constraint(equalTo: topBar.bottomAnchor), threadPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            threadPane.trailingAnchor.constraint(equalTo: root.trailingAnchor), threadWidth,

            header.topAnchor.constraint(equalTo: mainPane.topAnchor), header.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor), header.heightAnchor.constraint(equalToConstant: ChannelHeader.height),
            list.topAnchor.constraint(equalTo: header.bottomAnchor), list.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -4),
            list.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor), list.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            composer.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor, constant: 20), composer.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor, constant: -20),
            composer.bottomAnchor.constraint(equalTo: mainPane.bottomAnchor, constant: -20),
            toast.centerXAnchor.constraint(equalTo: mainPane.centerXAnchor), toast.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -16),

            line2.topAnchor.constraint(equalTo: threadPane.topAnchor), line2.bottomAnchor.constraint(equalTo: threadPane.bottomAnchor),
            line2.leadingAnchor.constraint(equalTo: threadPane.leadingAnchor), line2.widthAnchor.constraint(equalToConstant: 1),
            threadHeader.topAnchor.constraint(equalTo: threadPane.topAnchor), threadHeader.leadingAnchor.constraint(equalTo: line2.trailingAnchor),
            threadHeader.trailingAnchor.constraint(equalTo: threadPane.trailingAnchor), threadHeader.heightAnchor.constraint(equalToConstant: ChannelHeader.height),
            thread.topAnchor.constraint(equalTo: threadHeader.bottomAnchor), thread.bottomAnchor.constraint(equalTo: threadComposer.topAnchor, constant: -4),
            thread.leadingAnchor.constraint(equalTo: line2.trailingAnchor), thread.trailingAnchor.constraint(equalTo: threadPane.trailingAnchor),
            threadComposer.leadingAnchor.constraint(equalTo: line2.trailingAnchor, constant: 16), threadComposer.trailingAnchor.constraint(equalTo: threadPane.trailingAnchor, constant: -16),
            threadComposer.bottomAnchor.constraint(equalTo: threadPane.bottomAnchor, constant: -20),
        ])
        threadPane.isHidden = true
        threadHeader.title = "Thread"
        threadHeader.closable = true
    }

    private func wire() {
        sidebar.onSelect = { [weak self] c in self?.open(c.id) }
        sidebar.onTop = { [weak self] t in
            switch t {
            case .threads: self?.run(.threads)
            case .drafts: self?.run(.drafts)
            case .mentions: self?.showMentions()
            }
        }
        sidebar.onToggle = { [weak self] id in self?.toggleCollapsed(id) }
        sidebar.onHeaderMenu = { [weak self] g, v, p in self?.sectionMenu(g, in: v, at: p) }
        sidebar.header.onName = { [weak self] in self?.showPalette(query: "> workspace") }
        sidebar.header.onCompose = { [weak self] in self?.showPalette(query: "@") }
        sidebar.avatar = { [weak self] c in (c.userID ?? c.id, c.userID.flatMap { self?.store.person($0)?.image48 }) }
        topBar.placeholder = "Search \(store.get("team") ?? workspace)"
        topBar.onSearch = { [weak self] in self?.showSearch() }
        topBar.onBack = { [weak self] in self?.run(.back) }
        topBar.onForward = { [weak self] in self?.run(.forward) }
        header.onStar = { [weak self] in self?.run(.star) }
        header.onName = { [weak self] in self?.showPalette(query: "> channel") }
        header.onSearch = { [weak self] in self?.showSearch(scope: self?.current) }
        threadHeader.onClose = { [weak self] in self?.closeThread() }
        threadHeader.onSubtitle = { [weak self] in self?.closeThread() }

        list.empty.stringValue = "No messages cached yet"
        thread.empty.stringValue = ""
        thread.inThread = true
        thread.focused = false
        for (l, inThread) in [(list, false), (thread, true)] {
            l.actions = actions(for: l, inThread: inThread)
            l.makeEditorTextView = { [weak self] in self?.makeComposerTextView() ?? ComposerTextView() }
        }
        for (c, inThread) in [(composer, false), (threadComposer, true)] {
            configure(c, inThread: inThread)
        }
        Avatars.shared.onLoad = { [weak self] id in self?.avatarLoaded(id) }

        sync?.onChange = { [weak self] s in self?.cacheChanged(s) }
        sync?.onProgress = { [weak self] s in self?.progress(s) }
        sync?.onError = { [weak self] e in self?.failed(e) }
        outbox?.onChange = { [weak self] s in self?.cacheChanged(s) }
        outbox?.onError = { [weak self] item, e in self?.outboxFailed(item, e) }
    }

    // MARK: first frame

    /// Everything here reads the cache only: the window is drawn before
    /// any network call, with the channel, thread, scroll and drafts restored (L3).
    func showFirstFrame() {
        do { try outbox?.resume() } catch { report(error, "outbox resume") }
        loadLocalState()
        let convs = cached({ try store.conversations() }) ?? []
        let saved = (cachedUI(.current)) ?? store.get("ui.current")
        let first = convs.first { $0.id == saved } ?? convs.first { $0.name == "general" } ?? convs.first
        Launch.mark("convs")
        current = first
        list.context = context()
        thread.context = list.context
        showSidebar(convs)
        if let first { showChannel(first, restore: true) }
        if let t = cachedUI(.openThread), t.channel == first?.id { openThread(ts: t.ts, focus: false) }
        Launch.mark("rows")
        sidebar.workspace = store.get("team") ?? workspace
        sidebar.status = syncProblem
        if Launch.headless { window.setFrameOrigin(NSPoint(x: -20000, y: -20000)) } else { window.makeKeyAndOrderFront(nil) }
        Launch.mark("ordered")
        window.displayIfNeeded()
        CATransaction.flush()
        Launch.firstFrame = Launch.sinceStart
        Launch.mark("frame")
    }

    private func loadLocalState() {
        starred = cachedUI(.starred) ?? []
        collapsedGroups = Set(cachedUI(.collapsedGroups) ?? [])
        if let s = cachedUI(.sections) {
            sections = s
        } else {
            sections = Sections.seed(config.sections ?? [])
            setUI(.sections, sections)
        }
        if cachedUI(.sidebarVisible) == false { sidebarWidth.constant = 0; sidebar.isHidden = true }
        topBar.sidebarWidth = sidebarWidth.constant
    }

    func start() {
        guard let sync else { return }
        lastRefresh = Date()
        let first = current?.id
        sync.run { s in
            try await s.all(first: first)
            await s.directory()
        }
        startLive(sync)
        if let id = current?.id { sync.members(id) }
        NotificationCenter.default.addObserver(self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// The app token is a keychain read (a process spawn), so it happens
    /// off main, after the first frame.
    private func startLive(_ sync: Sync) {
        let source = appToken
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let token = source()
            DispatchQueue.main.async {
                guard let self else { return }
                let l = Live(store: self.store, sync: sync, appToken: token)
                l.onChange = { [weak self] s in self?.cacheChanged(s) }
                l.onError = { [weak self] e in self?.failed(e) }
                l.onStatus = { [weak self] s in self?.liveChanged(s) }
                self.live = l
                l.watch(channel: self.current?.id, thread: self.threadTS)
                l.start()
            }
        }
    }

    /// Back in front: catch up on the open channel, and everything if it's been a while.
    @objc private func activated() {
        guard let sync, let id = current?.id else { return }
        let since = Date().timeIntervalSince(lastRefresh)
        guard since > 20 else { return }
        lastRefresh = Date()
        if since > 600 { sync.run { try await $0.all(first: id) } } else { sync.run { try await $0.newer(id) } }
    }

    func refresh() {
        guard let sync else { toast.show(syncProblem ?? "No connection", error: true); return }
        lastRefresh = Date()
        let id = current?.id
        sync.run { try await $0.all(first: id) }
    }

    // MARK: cache → screen

    func cacheChanged(_ channels: Set<String>) {
        mentionIndexStale = true
        if let id = current?.id, channels.contains(id) || channels.isEmpty {
            if let ms = cached({ try store.messages(id, limit: max(200, list.messages.filter { $0.id > 0 }.count)) }) {
                list.context.draftThreads = cached({ try store.draftThreads(id) }) ?? []
                list.show(ms, mode: .keep)
            }
            if let ts = threadTS { thread.show(cached({ try store.thread(id, ts: ts) }) ?? [], mode: .keep) }
        }
        reloadSidebar()
    }

    func reloadSidebar() {
        guard let convs = cached({ try store.conversations() }) else { return }
        if current == nil, let first = convs.first { open(first.id); return }
        if let id = current?.id, let c = convs.first(where: { $0.id == id }) { current = c; header.conversation = c }
        showSidebar(convs)
        sidebar.workspace = store.get("team") ?? workspace
    }

    func showSidebar(_ convs: [Conversation]) {
        let p = Sections.place(convs, sections: sections, starred: starred, collapsed: collapsedGroups, current: current?.id, drafts: [])
        if !p.missing.isEmpty, p.missing != lastMissing { log("sidebar: section entries not in the cache: \(p.missing.joined(separator: ", "))"); lastMissing = p.missing }
        sidebar.draftCount = (cached({ try store.drafts() }) ?? []).count
        sidebar.show(convs, groups: p.groups, current: current?.id)
    }
    private var lastMissing: [String] = []

    /// Cache reads that fail say so on screen and in the log; the view
    /// keeps what it had rather than pretending the cache is empty.
    func cached<T>(_ read: () throws -> T) -> T? {
        do { return try read() } catch {
            report(error, "cache")
            return nil
        }
    }

    func cachedUI<T>(_ k: UIKey<T>) -> T? { cached { try store.ui(k) } ?? nil }

    func setUI<T>(_ k: UIKey<T>, _ v: T?) {
        do { try store.setUI(k, v) } catch { report(error, "save \(k.name)") }
    }

    func report(_ e: Error, _ what: String) {
        log("\(what): \(e)")
        toast.show("\(e)", error: true)
    }

    private func progress(_ s: String?) {
        sidebar.status = s ?? liveStatus ?? syncProblem
        if s == nil { topBar.placeholder = "Search \(store.get("team") ?? workspace)" }
    }

    private func failed(_ e: Error) {
        toast.show("\(e)", error: true)
        sidebar.status = "Offline: \(e)"
    }

    private func liveChanged(_ s: Live.Status) {
        switch s {
        case .live, .stopped, .connecting: liveStatus = nil
        case .reconnecting(let after, let error): liveStatus = String(format: "Reconnecting in %.0fs: %@", after, error)
        case .polling(let reason): liveStatus = "polling (\(reason))"
        }
        sidebar.status = liveStatus ?? syncProblem
    }

    private func outboxFailed(_ item: OutboxItem, _ e: Error) {
        toast.dismissUndo()
        let what = item.kind == .send ? "Not sent" : item.kind == .edit ? "Edit failed" : "Delete failed"
        report(e, "\(what) (\(item.channel))")
    }

    private func avatarLoaded(_ id: String) {
        list.avatarLoaded(id)
        thread.avatarLoaded(id)
        sidebar.reloadAvatar(id)
        if current?.userID == id { header.avatar = headerAvatar(current) }
    }

    // MARK: context

    func context() -> MessageListContext {
        var c = MessageListContext()
        c.me = store.me
        c.person = { [store] in store.person($0) }
        c.name = { [store] in store.name(of: $0) }
        let byID = Dictionary((cached({ try store.conversations() }) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        c.channelName = { byID[$0] }
        let groups = Dictionary((cached({ try store.usergroups() }) ?? []).map { ($0.id, $0.handle) }, uniquingKeysWith: { a, _ in a })
        c.groupHandle = { groups[$0] }
        c.customEmoji = cached({ try store.customEmoji() }) ?? [:]
        c.writes = writes
        c.threadUnread = { [weak self] ts in
            guard let self, let id = self.current?.id, let m = self.list.messages.first(where: { $0.ts == ts }), let latest = m.latestReply else { return false }
            let read = self.cachedUI(UIKey<String>.threadRead(id, ts)) ?? ts
            return ListLayout.tsLess(read, latest)
        }
        return c
    }

    // MARK: navigation

    func open(_ id: String, at ts: String? = nil, recordHistory: Bool = true) {
        guard let c = cached({ try store.conversation(id) }) ?? nil else {
            toast.show("\(id) isn't in the cache yet", error: true)
            return
        }
        if let old = current, old.id != id {
            saveScroll()
            if recordHistory { history.append(old.id); future = [] }
        }
        closeThread()
        current = c
        setUI(.current, id)
        var recents = cachedUI(.recents) ?? []
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        setUI(.recents, Array(recents.prefix(20)))
        let t0 = CACurrentMediaTime()
        showChannel(c, restore: ts == nil, at: ts)
        sidebar.select(id)
        reloadSidebar()
        log(String(format: "switch %@ %.1fms", id, (CACurrentMediaTime() - t0) * 1000))
        topBar.canBack = !history.isEmpty
        topBar.canForward = !future.isEmpty
        live?.watch(channel: id, thread: nil)
        sync?.run { try await $0.newer(id) }
        sync?.members(id)
    }

    func showChannel(_ c: Conversation, restore: Bool, at ts: String? = nil) {
        header.conversation = c
        header.starred = starred.contains(c.id)
        header.avatar = headerAvatar(c)
        var ms = cached({ try store.messages(c.id) }) ?? []
        if let ts, !ms.contains(where: { $0.ts == ts }) { ms = cached({ try store.messages(c.id, limit: 2000) }) ?? ms }
        list.context.draftThreads = cached({ try store.draftThreads(c.id) }) ?? []
        if let ts {
            list.show(ms, mode: .at(ts: ts))
        } else {
            let unreadAfter = c.unread > 0 ? c.lastRead : nil
            list.show(ms, mode: .open(unreadAfter: unreadAfter, restore: restore ? cachedUI(.scroll(c.id)) : nil))
        }
        composer.placeholder = "Message \(c.label)"
        composer.switchTo(channel: c.id, thread: nil, draft: cached({ try store.draft(c.id, thread: nil) }) ?? nil, decode: decodeDraft)
    }

    func headerAvatar(_ c: Conversation?) -> CGImage? {
        guard let c, c.kind == .im, let u = c.userID else { return nil }
        return Avatars.shared.layerContents(for: u, name: c.name, url: store.person(u)?.image48, size: 20)
    }

    func saveScroll() {
        guard let c = current else { return }
        setUI(.scroll(c.id), list.atBottom ? nil : list.scrollAnchor)
    }

    /// Saves what's only in memory: drafts in flight and the scroll position.
    func saveState() {
        composer.flushDraft()
        threadComposer.flushDraft()
        saveScroll()
    }

    func loadOlder() {
        guard let sync, let id = current?.id, !loadingOlder, !store.syncState(id).complete else { return }
        loadingOlder = true
        sync.run { [weak self] s in
            defer { DispatchQueue.main.async { self?.loadingOlder = false } }
            _ = try await s.older(id)
        }
    }

    func openThread(ts root: String, focus: Bool) {
        guard let c = current else { return }
        threadComposer.flushDraft()
        threadTS = root
        threadPane.isHidden = false
        threadWidth.constant = CGFloat(cachedUI(.threadWidth) ?? 400)
        threadHeader.subtitle = c.label
        let ms = cached({ try store.thread(c.id, ts: root) }) ?? []
        let unread = cached({ try store.firstUnread(c.id, thread: root) }) ?? nil
        let read = cachedUI(UIKey<String>.threadRead(c.id, root))
        thread.context = list.context
        thread.show(ms, mode: .open(unreadAfter: unread != nil ? read : nil, restore: nil))
        threadComposer.placeholder = "Reply…"
        threadComposer.switchTo(channel: c.id, thread: root, draft: cached({ try store.draft(c.id, thread: root) }) ?? nil, decode: decodeDraft)
        setUI(.openThread, ThreadRef(channel: c.id, ts: root))
        focusThread(focus)
        live?.watch(channel: c.id, thread: root)
        if let parent = ms.first, parent.replyCount > 0 || ms.count > 1 || parent.threadTS != nil { sync?.run { try await $0.thread(c.id, ts: root) } }
    }

    func openThread() {
        guard let m = focusedList.selectedMessage else { return }
        openThread(ts: m.threadTS ?? m.ts, focus: true)
    }

    func closeThread() {
        guard threadTS != nil else { return }
        threadComposer.flushDraft()
        threadComposer.switchTo(channel: "", thread: nil, draft: nil, decode: decodeDraft)
        threadTS = nil
        thread.show([], mode: .open(unreadAfter: nil, restore: nil))
        threadPane.isHidden = true
        threadWidth.constant = 0
        setUI(.openThread, nil)
        focusThread(false)
        live?.watch(channel: current?.id, thread: nil)
    }

    func focusThread(_ on: Bool) {
        threadFocused = on && threadTS != nil
        thread.focused = threadFocused
        list.focused = !threadFocused
        let r = window.firstResponder
        if window.isEditingText, !(composer.owns(r) || threadComposer.owns(r)) { return }
        if composer.owns(r) || threadComposer.owns(r) { window.makeFirstResponder(nil) }
    }

    var focusedList: MessageList { threadFocused ? thread : list }
    var focusedComposer: Composer { threadFocused ? threadComposer : composer }

    func jumpToUnread() {
        let unread = sidebar.allConversations.filter { ($0.unread > 0 || $0.mentions > 0) && $0.id != current?.id }
        let order = sidebar.conversations.map(\.id)
        let sorted = unread.sorted { a, b in
            if (a.mentions > 0) != (b.mentions > 0) { return a.mentions > 0 }
            return (order.firstIndex(of: a.id) ?? .max) < (order.firstIndex(of: b.id) ?? .max)
        }
        guard let c = sorted.first else { toast.show("All caught up", kind: .success); return }
        open(c.id)
    }

    func toggleCollapsed(_ id: String) {
        if let i = sections.firstIndex(where: { $0.id == id }) {
            sections[i].collapsed.toggle()
            setUI(.sections, sections)
        } else {
            if collapsedGroups.contains(id) { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
            setUI(.collapsedGroups, collapsedGroups.sorted())
        }
        reloadSidebar()
    }

    func windowDidBecomeKey(_ notification: Notification) { live?.setVisible(true) }
    func windowDidMiniaturize(_ notification: Notification) { live?.setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { live?.setVisible(true) }
    func windowWillClose(_ notification: Notification) { saveState() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.bg.cgColor }
}
