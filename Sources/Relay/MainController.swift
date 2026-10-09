import AppKit
import RelayCore

/// One window: sidebar, the channel, and a thread pane that opens on r.
final class MainController: NSObject, NSWindowDelegate {
    let config: Config
    let workspace: String
    let store: Store
    let sync: Sync?
    private let syncProblem: String?

    let window: KeyWindow
    let sidebar = Sidebar()
    let list = MessageList()
    let thread = MessageList()
    private let title = NSTextField(labelWithString: "")
    private let threadTitle = NSTextField(labelWithString: "Thread")
    private let threadPane = NSView()
    private var threadWidth: NSLayoutConstraint!
    let toast = Toast()
    private let root = NSView()

    private(set) var current: Conversation?
    private(set) var threadTS: String?
    private var threadFocused = false
    private var overlay: PickerOverlay?
    private var pendingG = false
    private var loadingOlder = false
    private var lastRefresh = Date.distantPast
    var onSwitchWorkspace: ((String) -> Void)?

    init(config: Config, workspace: String, store: Store, sync: Sync?, syncProblem: String?) {
        self.config = config
        self.workspace = workspace
        self.store = store
        self.sync = sync
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
        window.backgroundColor = Palette.background
        window.router = { [weak self] e in self?.key(e) ?? false }
        layout()
        Launch.mark("layout")
        sidebar.workspace = store.get("team") ?? workspace
        sidebar.onSelect = { [weak self] c in self?.open(c.id) }
        list.names = store.name(of:)
        thread.names = store.name(of:)
        thread.inThread = true
        thread.focused = false
        list.empty.stringValue = "No messages cached yet"
        thread.empty.stringValue = ""
        list.onNearTop = { [weak self] in self?.loadOlder() }
        list.onOpen = { [weak self] i in self?.list.select(i); self?.openThread() }
        sync?.onChange = { [weak self] s in self?.cacheChanged(s) }
        sync?.onProgress = { [weak self] s in self?.progress(s) }
        sync?.onError = { [weak self] e in self?.failed(e) }
    }

    private func layout() {
        window.contentView = root
        let main = NSView()
        let header = NSView()
        let threadHeader = NSView()
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.lineBreakMode = .byTruncatingTail
        threadTitle.font = .systemFont(ofSize: 14, weight: .bold)
        threadPane.wantsLayer = true
        let line = NSBox(); line.boxType = .separator
        let line2 = NSBox(); line2.boxType = .separator
        for v in [sidebar, main, threadPane, toast, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        for v in [header, list] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; main.addSubview(v) }
        for v in [threadHeader, thread, line2] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; threadPane.addSubview(v) }
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        threadTitle.translatesAutoresizingMaskIntoConstraints = false
        threadHeader.addSubview(threadTitle)
        threadWidth = threadPane.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.widthAnchor.constraint(equalToConstant: Sidebar.width),
            line.topAnchor.constraint(equalTo: root.topAnchor), line.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), line.widthAnchor.constraint(equalToConstant: 1),
            main.topAnchor.constraint(equalTo: root.topAnchor), main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: line.trailingAnchor), main.trailingAnchor.constraint(equalTo: threadPane.leadingAnchor),
            threadPane.topAnchor.constraint(equalTo: root.topAnchor), threadPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            threadPane.trailingAnchor.constraint(equalTo: root.trailingAnchor), threadWidth,
            header.topAnchor.constraint(equalTo: main.topAnchor), header.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: main.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 52),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -18),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 2),
            list.topAnchor.constraint(equalTo: header.bottomAnchor), list.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: main.leadingAnchor), list.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            line2.topAnchor.constraint(equalTo: threadPane.topAnchor), line2.bottomAnchor.constraint(equalTo: threadPane.bottomAnchor),
            line2.leadingAnchor.constraint(equalTo: threadPane.leadingAnchor), line2.widthAnchor.constraint(equalToConstant: 1),
            threadHeader.topAnchor.constraint(equalTo: threadPane.topAnchor), threadHeader.leadingAnchor.constraint(equalTo: line2.trailingAnchor),
            threadHeader.trailingAnchor.constraint(equalTo: threadPane.trailingAnchor), threadHeader.heightAnchor.constraint(equalToConstant: 52),
            threadTitle.leadingAnchor.constraint(equalTo: threadHeader.leadingAnchor, constant: 18),
            threadTitle.centerYAnchor.constraint(equalTo: threadHeader.centerYAnchor, constant: 2),
            thread.topAnchor.constraint(equalTo: threadHeader.bottomAnchor), thread.bottomAnchor.constraint(equalTo: threadPane.bottomAnchor),
            thread.leadingAnchor.constraint(equalTo: line2.trailingAnchor), thread.trailingAnchor.constraint(equalTo: threadPane.trailingAnchor),
            toast.centerXAnchor.constraint(equalTo: main.centerXAnchor), toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        threadPane.isHidden = true
    }

    // MARK: first frame

    /// Everything here reads the cache only: the window is drawn before
    /// any network call.
    func showFirstFrame() {
        let convs = cached({ try store.conversations() }) ?? []
        let saved = store.get("ui.current")
        let first = convs.first { $0.id == saved } ?? convs.first { $0.name == "general" } ?? convs.first
        Launch.mark("convs")
        current = first
        sidebar.show(convs, sections: config.sections ?? [], current: first?.id)
        if let first { showChannel(first, cursor: nil) }
        Launch.mark("rows")
        sidebar.status.stringValue = syncProblem ?? lastSyncedText
        window.makeKeyAndOrderFront(nil)
        Launch.mark("ordered")
        window.displayIfNeeded()
        CATransaction.flush()
        Launch.firstFrame = Launch.sinceStart
        Launch.mark("frame")
    }

    private var lastSyncedText: String {
        guard let s = store.get("synced_at"), let t = Double(s) else { return "Never synced" }
        let ago = Date().timeIntervalSince1970 - t
        if ago < 60 { return "Synced just now" }
        return "Synced " + RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())
    }

    func start() {
        guard let sync else { return }
        lastRefresh = Date()
        let first = current?.id
        sync.run { try await $0.all(first: first) }
        NotificationCenter.default.addObserver(self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// Back in front: catch up on the open channel, and everything if it's
    /// been a while.
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

    private func cacheChanged(_ channels: Set<String>) {
        if let id = current?.id, channels.contains(id), let ms = cached({ try store.messages(id) }) {
            list.show(ms)
            if window.isKeyWindow, let last = ms.last?.ts { _ = cached { try store.markSeen(id, last) } }
            if let ts = threadTS { thread.show(cached({ try store.thread(id, ts: ts) }) ?? []) }
        }
        reloadSidebar()
    }

    private func reloadSidebar() {
        guard let convs = cached({ try store.conversations() }) else { return }
        if current == nil, let first = convs.first { open(first.id); return }
        sidebar.show(convs, sections: config.sections ?? [], current: current?.id)
        sidebar.workspace = store.get("team") ?? workspace
    }

    /// Cache reads that fail say so on screen and in the log; the view
    /// keeps what it had rather than pretending the cache is empty.
    private func cached<T>(_ read: () throws -> T) -> T? {
        do { return try read() } catch {
            log("cache: \(error)")
            toast.show("Cache error: \(error)", error: true)
            return nil
        }
    }

    private func progress(_ s: String?) { sidebar.status.stringValue = s ?? lastSyncedText }

    private func failed(_ e: Error) {
        toast.show("\(e)", error: true)
        sidebar.status.stringValue = "Sync failed: \(e)"
    }

    // MARK: navigation

    func open(_ id: String, at ts: String? = nil) {
        guard let c = (cached({ try store.conversations() }) ?? []).first(where: { $0.id == id }) else {
            toast.show("\(id) isn't in the cache yet", error: true)
            return
        }
        closeThread()
        current = c
        store.set("ui.current", id)
        var ms = cached({ try store.messages(id) }) ?? []
        if let ts, !ms.contains(where: { $0.ts == ts }) { ms = cached({ try store.messages(id, limit: 2000) }) ?? ms }
        showChannel(c, messages: ms, cursor: ts.flatMap { t in ms.firstIndex { $0.ts == t } })
        if let last = ms.last?.ts { _ = cached { try store.markSeen(id, last) } }
        reloadSidebar()
        sync?.run { try await $0.newer(id) }
    }

    private func showChannel(_ c: Conversation, messages: [Message]? = nil, cursor: Int?) {
        title.stringValue = c.label
        list.show(messages ?? cached({ try store.messages(c.id) }) ?? [], keep: false, cursor: cursor)
    }

    private func loadOlder() {
        guard let sync, let id = current?.id, !loadingOlder, !store.syncState(id).complete else { return }
        loadingOlder = true
        sync.run { [weak self] s in
            defer { DispatchQueue.main.async { self?.loadingOlder = false } }
            try await s.older(id)
        }
    }

    func openThread() {
        guard let c = current, let m = list.selectedMessage else { return }
        let root = m.threadTS ?? m.ts
        threadTS = root
        threadPane.isHidden = false
        threadWidth.constant = 400
        threadTitle.stringValue = "Thread in \(c.label)"
        thread.show(cached({ try store.thread(c.id, ts: root) }) ?? [m], keep: false, cursor: nil)
        focusThread(true)
        if m.replyCount > 0 || m.threadTS != nil { sync?.run { try await $0.thread(c.id, ts: root) } }
    }

    func closeThread() {
        threadTS = nil
        threadPane.isHidden = true
        threadWidth.constant = 0
        focusThread(false)
    }

    private func focusThread(_ on: Bool) {
        threadFocused = on && threadTS != nil
        thread.focused = threadFocused
        list.focused = !threadFocused
    }

    private var focusedList: MessageList { threadFocused ? thread : list }

    func jumpToUnread() {
        let unread = sidebar.conversations.filter { $0.unread > 0 && $0.id != current?.id }
        guard let c = unread.first else { toast.show("All caught up"); return }
        open(c.id)
    }

    // MARK: overlays

    private func present(_ o: PickerOverlay) {
        overlay?.removeFromSuperview()
        overlay = o
        o.onClose = { [weak self] in self?.dismissOverlay() }
        o.show(in: root)
        o.focus()
    }

    private func dismissOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
        window.makeFirstResponder(nil)
    }

    func showCommands() {
        let convs = sidebar.conversations
        var items = convs.map { c in
            PickerOverlay.Item(title: c.label, detail: c.unread > 0 ? "\(c.unread) unread" : (c.isDM ? "direct message" : "channel")) { [weak self] in self?.open(c.id) }
        }
        items.append(.init(title: "Jump to unreads", detail: "g u") { [weak self] in self?.jumpToUnread() })
        items.append(.init(title: "Search messages", detail: "/") { [weak self] in self?.showSearch() })
        items.append(.init(title: "Refresh", detail: "⌘R") { [weak self] in self?.refresh() })
        for name in config.workspaces.keys.sorted() where name != workspace {
            items.append(.init(title: "Switch to \(name)", detail: "workspace") { [weak self] in self?.onSwitchWorkspace?(name) })
        }
        present(CommandOverlay(items))
    }

    func showSearch() {
        let o = SearchOverlay(store: store, sync: sync)
        o.onHit = { [weak self] h in self?.open(h.channel, at: h.ts) }
        present(o)
    }

    // MARK: keys

    private func key(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let opt = e.modifierFlags.contains(.option)
        let ch = e.charactersIgnoringModifiers ?? ""
        if cmd {
            switch ch {
            case "k": if overlay is CommandOverlay { dismissOverlay() } else { showCommands() }; return true
            case "r": refresh(); return true
            case "f": showSearch(); return true
            default: return false
            }
        }
        if let overlay { return overlay.handle(e) }
        if window.isEditingText { return false }
        if opt, e.keyCode == 125 || e.keyCode == 126 {
            if let c = sidebar.neighbour(e.keyCode == 125 ? 1 : -1) { open(c.id) }
            return true
        }
        if pendingG {
            pendingG = false
            switch ch {
            case "u": jumpToUnread()
            case "g": focusedList.select(0)
            default: break
            }
            return true
        }
        switch e.keyCode {
        case 125: focusedList.step(1); return true
        case 126: focusedList.step(-1); return true
        case 53:
            if threadFocused { focusThread(false) } else if threadTS != nil { closeThread() }
            return true
        case 36: if !threadFocused { openThread() }; return true
        case 48: if threadTS != nil { focusThread(!threadFocused) }; return true
        default: break
        }
        switch ch {
        case "j": focusedList.step(1)
        case "k": focusedList.step(-1)
        case "G": focusedList.select(focusedList.messages.count - 1)
        case "g": pendingG = true
        case "r": openThread()
        case "/": showSearch()
        case "e", "+", "z": toast.show("Read-only for now: writes come in milestone 2")
        default: return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {}
}
