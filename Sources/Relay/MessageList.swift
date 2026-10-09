import AppKit
import RelayCore

struct MessageListContext {
    var me: String?
    var person: (String) -> Person? = { _ in nil }
    var name: (String) -> String = { $0 }
    var channelName: (String) -> String? = { _ in nil }
    var groupHandle: (String) -> String? = { _ in nil }
    var customEmoji: [String: String] = [:]
    var draftThreads: Set<String> = []
    var threadUnread: (String) -> Bool = { _ in false }
    var writes = false
}

enum ShowMode: Equatable {
    case keep
    case open(unreadAfter: String?, restore: ScrollAnchor?)
    case at(ts: String)
}

struct LinkRef: Equatable { var url: URL; var label: String; var ts: String; var author: String }

struct MessageActions {
    var react: (Message) -> Void = { _ in log("unwired: react") }
    var toggleReaction: (Message, String) -> Void = { _, _ in log("unwired: toggleReaction") }
    var quickReactions: () -> [String] = { ["+1", "eyes", "white_check_mark"] }
    var reply: (Message) -> Void = { _ in log("unwired: reply") }
    var copyLink: (Message) -> Void = { _ in log("unwired: copyLink") }
    var save: (Message) -> Void = { _ in log("unwired: save") }
    var edit: (Message) -> Void = { _ in log("unwired: edit") }
    var saveEdit: (Message, String) -> Void = { _, _ in log("unwired: saveEdit") }
    var delete: (Message) -> Void = { _ in log("unwired: delete") }
    var more: (Message) -> Void = { _ in log("unwired: more") }
    var retry: (Message) -> Void = { _ in log("unwired: retry") }
    var openThread: (Message) -> Void = { _ in log("unwired: openThread") }
    var openUser: (String, NSRect) -> Void = { _, _ in log("unwired: openUser") }
    var openChannel: (String) -> Void = { _ in log("unwired: openChannel") }
    var openURL: (URL, Bool) -> Void = { _, _ in log("unwired: openURL") }
    var nearTop: () -> Void = {}
    var bottomVisible: () -> Void = {}
    var markRead: () -> Void = {}
}

/// One message as drawn: parsed once, its body built once per version, its
/// geometry once per width. Hover and the cursor never touch it.
final class RowEntry {
    var message: Message
    var blocks: [Mrkdwn.Block]
    var body: Body
    var bodyHeight: (width: CGFloat, height: CGFloat)?
    var grouped = false
    var lastInGroup = true
    var geo: RowGeometry?

    init(message: Message, blocks: [Mrkdwn.Block], body: Body) {
        self.message = message
        self.blocks = blocks
        self.body = body
    }

    func sameBody(_ m: Message) -> Bool { message.text == m.text && message.edited == m.edited && message.local == m.local }
}

/// The table under the list: one tracking area for hover, and clicks pass
/// through to the drawn controls inside cells.
final class MessageTable: NSTableView {
    var onMouse: ((NSPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { onMouse?(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { onMouse?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMouse?(nil) }
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}

/// Messages as recycled rows (§5): avatars, grouping, mrkdwn bodies,
/// reaction pills, thread summaries, day separators, the New divider, the
/// shared hover bar, sticky day and jump pills, and edit in place. Used for
/// the channel and for the thread pane.
final class MessageList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var context = MessageListContext() { didSet { contextChanged() } }
    var actions = MessageActions()
    var inThread = false
    var focused = true { didSet { if focused != oldValue { updateSelectionStyle() } } }
    var makeEditorTextView: () -> NSTextView = { ComposerTextView() }

    private(set) var messages: [Message] = []
    private var items: [ListItem] = []
    private var rowOf: [Int] = []
    private var indexOfTS: [String: Int] = [:]
    private var entries: [RowEntry] = []
    private var cache: [String: RowEntry] = [:]
    private var dayRows: [Int] = []
    private var unreadRow: Int?
    private var unreadAfter: String?
    private var width: CGFloat = 0
    private var newWhileScrolledUp = 0

    private(set) var table: NSTableView!
    private var scroll: NSScrollView!
    private let hoverBar = HoverBar()
    private let sticky = StickyDay()
    private let jumpTop = JumpPill()
    private let jumpBottom = JumpPill()
    private lazy var editor: InlineEditor = makeEditor()
    private var editingTS: String?
    private var editorHeight: CGFloat = 0
    private var confirmingTS: String?
    private var hoveredRow: Int? { didSet { if hoveredRow != oldValue { hoverChanged(from: oldValue) } } }
    private var mouseInside = false
    private var stillCursor: DispatchWorkItem?
    private var bottomTimer: DispatchWorkItem?

    // compatibility until SHELL moves to `context` / `actions` / `show(_:mode:)`
    var names: (String) -> String { get { context.name } set { context.name = newValue } }
    var onNearTop: (() -> Void)?
    var onOpen: ((Int) -> Void)?
    let empty = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.bg.cgColor }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let t = MessageTable()
        let col = NSTableColumn(identifier: .init("c"))
        col.resizingMask = .autoresizingMask
        t.addTableColumn(col)
        t.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        t.headerView = nil
        t.intercellSpacing = .zero
        t.style = .plain
        t.backgroundColor = .clear
        t.selectionHighlightStyle = .regular
        t.dataSource = self
        t.delegate = self
        t.refusesFirstResponder = true
        t.target = self
        t.action = #selector(clicked)
        t.doubleAction = #selector(doubleClicked)
        t.onMouse = { [weak self] p in self?.mouse(at: p) }
        let s = NSScrollView()
        s.documentView = t
        s.drawsBackground = false
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        s.automaticallyAdjustsContentInsets = false
        table = t
        scroll = s
        pin(s, in: self)
        for v in [sticky, jumpTop, jumpBottom, hoverBar] as [NSView] { addSubview(v) }
        empty.textColor = Theme.textMuted
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor)])
        s.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: s.contentView)
        hoverBar.onAction = { [weak self] a in self?.barAction(a) }
        hoverBar.onConfirm = { [weak self] yes in self?.finishConfirm(yes) }
        sticky.onClick = { [weak self] _ in self?.jumpToDay() }
        jumpTop.onClick = { [weak self] p in self?.jumpTopClicked(p) }
        jumpBottom.onClick = { [weak self] _ in self?.scrollToBottom() }
        jumpBottom.kind = .bottom(newCount: 0)
        _ = Body.pBody
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: public surface

    var selected: Int? {
        let r = table.selectedRow
        guard r >= 0, r < items.count, case .message(let i, _) = items[r] else { return nil }
        return i
    }

    var selectedMessage: Message? { selected.map { messages[$0] } }
    var isEditing: Bool { editingTS != nil }

    var scrollAnchor: ScrollAnchor? {
        let visible = scroll.contentView.bounds
        let rows = table.rows(in: visible)
        for r in rows.location..<(rows.location + rows.length) where r < items.count {
            guard case .message(let i, _) = items[r] else { continue }
            let rect = table.rect(ofRow: r)
            guard rect.maxY > visible.minY else { continue }
            return ScrollAnchor(ts: messages[i].ts, offset: Double(rect.minY - visible.minY))
        }
        return nil
    }

    var visibleLinks: [LinkRef] {
        let rows = table.rows(in: scroll.contentView.bounds)
        var out: [LinkRef] = []
        for r in (rows.location..<(rows.location + rows.length)).reversed() where r < items.count {
            guard case .message(let i, _) = items[r] else { continue }
            let e = entries[i]
            for l in e.body.links { out.append(LinkRef(url: l.url, label: l.label, ts: e.message.ts, author: e.message.author)) }
        }
        return out
    }

    /// Compatibility: keeps the cursor on the same message when it's still
    /// there, and otherwise lands on `cursor` (default: the last row).
    func show(_ ms: [Message], keep: Bool = true, cursor: Int? = nil) {
        if keep { show(ms, mode: .keep); return }
        if let cursor, cursor < ms.count { show(ms, mode: .at(ts: ms[cursor].ts)); return }
        show(ms, mode: .open(unreadAfter: nil, restore: nil))
    }

    func show(_ ms: [Message], mode: ShowMode) {
        let t0 = CACurrentMediaTime()
        if width == 0 { window?.contentView?.layoutSubtreeIfNeeded() }
        let prevCursorTS = selectedMessage?.ts
        let atBottom = isAtBottom
        let anchor = scrollAnchor
        let prevLast = messages.last?.ts
        if case .open = mode { cancelEdit(); finishConfirm(false); newWhileScrolledUp = 0 }
        if case .open(let after, _) = mode { unreadAfter = after }
        if case .at = mode { unreadAfter = nil }

        messages = ms
        items = ListLayout.items(ms, unreadAfter: unreadAfter, inThread: inThread)
        index()
        let tIndex = CACurrentMediaTime()
        let built = prepareEntries()
        let tBuilt = CACurrentMediaTime()
        let w = currentWidth
        width = w
        layoutAll(width: w)
        let t1 = CACurrentMediaTime()
        if Brand.env("TIMING") != nil { print(String(format: "  layout+index %.1f build %.1f measure %.1f", (tIndex - t0) * 1000, (tBuilt - tIndex) * 1000, (t1 - tBuilt) * 1000)) }
        table.reloadData()
        empty.isHidden = !ms.isEmpty
        if let ts = editingTS, indexOfTS[ts] == nil { cancelEdit() }

        switch mode {
        case .keep:
            if let ts = prevCursorTS, let i = indexOfTS[ts] { selectRow(i) } else if selected == nil, !ms.isEmpty { selectRow(ms.count - 1) }
            if atBottom || anchor == nil {
                scrollToBottom()
            } else if let anchor {
                restore(anchor)
                if let prevLast, let last = ms.last?.ts, ListLayout.tsLess(prevLast, last) {
                    newWhileScrolledUp += ms.reversed().prefix { ListLayout.tsLess(prevLast, $0.ts) }.count
                }
            }
        case .open(_, let saved):
            if let u = unreadRow, let i = firstMessage(after: u) {
                selectRow(i)
                let rect = table.rect(ofRow: u)
                scrollTo(y: rect.minY - scroll.contentView.bounds.height / 3)
            } else if let saved, indexOfTS[saved.ts] != nil {
                restore(saved)
                if let i = indexOfTS[saved.ts] { selectRow(i) }
            } else if !ms.isEmpty {
                selectRow(ms.count - 1)
                scrollToBottom()
            }
        case .at(let ts):
            if let i = indexOfTS[ts] {
                selectRow(i)
                let rect = table.rect(ofRow: rowOf[i])
                scrollTo(y: rect.midY - scroll.contentView.bounds.height / 2)
            } else {
                log("show: \(ts) isn't among the \(ms.count) loaded messages")
                if !ms.isEmpty { selectRow(ms.count - 1); scrollToBottom() }
            }
        }
        updateOverlays()
        if let h = hoveredRow, h >= items.count { hoveredRow = nil }
        if !Self.warmed { Self.warmed = true; DispatchQueue.main.async { Symbols.warm() } }
        let ms1 = (CACurrentMediaTime() - t0) * 1000
        lastShowTiming = String(format: "show %d messages: %.1f ms (%d built, %.1f ms reload+scroll)", ms.count, ms1, built, (CACurrentMediaTime() - t1) * 1000)
        if ms1 > 16 || Brand.env("TIMING") != nil { log(lastShowTiming) }
        if Brand.env("TIMING") != nil { print(lastShowTiming); fflush(stdout) }
    }

    private(set) var lastShowTiming = ""
    private static var warmed = false

    /// Re-render only these messages: an author resolved, an avatar landed.
    func reload(ts: Set<String>) {
        var rows = IndexSet()
        for t in ts {
            guard let i = indexOfTS[t] else { continue }
            cache[t] = nil
            rows.insert(rowOf[i])
        }
        guard !rows.isEmpty else { return }
        _ = prepareEntries()
        layoutAll(width: width)
        table.noteHeightOfRows(withIndexesChanged: rows)
        table.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    func select(_ i: Int) {
        guard !messages.isEmpty else { return }
        selectRow(max(0, min(messages.count - 1, i)))
        table.scrollRowToVisible(table.selectedRow)
        cursorMoved()
    }

    func selectLast() { select(messages.count - 1) }
    func selectFirst() { select(0) }

    func step(_ d: Int) {
        guard let s = selected else { select(d > 0 ? 0 : messages.count - 1); return }
        let r = rowOf[s]
        if !table.visibleRect.intersects(table.rect(ofRow: r)) {
            table.scrollRowToVisible(r)
            cursorMoved()
            return
        }
        select(s + d)
        if s + d < 0 { onNearTop?(); actions.nearTop() }
    }

    func scrollToBottom() {
        guard !items.isEmpty else { return }
        let docH = table.bounds.height
        scrollTo(y: docH - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
        newWhileScrolledUp = 0
    }

    func jumpToUnread() {
        guard let u = unreadRow else { return }
        scrollTo(y: table.rect(ofRow: u).minY - scroll.contentView.bounds.height / 3)
        if let i = firstMessage(after: u) { selectRow(i) }
    }

    func jumpToNextMention() {
        let from = selected ?? -1
        guard let i = entries.indices.first(where: { $0 > from && mentionsMe(entries[$0]) }) ?? entries.indices.first(where: { mentionsMe(entries[$0]) }) else { return }
        select(i)
    }

    @discardableResult
    func beginEdit(ts: String) -> Bool {
        guard let i = indexOfTS[ts] else { return false }
        let r = rowOf[i]
        guard table.visibleRect.intersects(table.rect(ofRow: r)) else { return false }
        cancelEdit()
        let m = messages[i]
        let decoded = Mentions.decode(m.text) { [context] t in
            switch t {
            case .user(let id): return context.name(id)
            case .channel(let id): return context.channelName(id)
            case .group(let id): return context.groupHandle(id)
            case .special(let s): return s
            }
        }
        stillCursor?.cancel()
        hoveredRow = nil
        hoverBar.isHidden = true
        editingTS = ts
        editor.begin(m, text: decoded.text, tokens: decoded.tokens)
        editorHeight = editor.height(width: entries[i].geo?.contentWidth ?? 300)
        table.noteHeightOfRows(withIndexesChanged: [r])
        table.reloadData(forRowIndexes: [r], columnIndexes: [0])
        markEditing(r, true)
        table.scrollRowToVisible(r)
        placeEditor()
        editor.focus()
        return true
    }

    func cancelEdit() {
        guard let ts = editingTS else { return }
        editingTS = nil
        editor.end()
        if let i = indexOfTS[ts] {
            markEditing(rowOf[i], false)
            table.noteHeightOfRows(withIndexesChanged: [rowOf[i]])
            table.reloadData(forRowIndexes: [rowOf[i]], columnIndexes: [0])
        }
        if window?.firstResponder === editor.textView { window?.makeFirstResponder(nil) }
    }

    private func markEditing(_ r: Int, _ on: Bool) {
        guard let v = table.rowView(atRow: r, makeIfNecessary: false) as? MessageRowView else { return }
        v.editing = on
        if case .message(let i, _) = items[r] { v.mentionsMe = !on && mentionsMe(entries[i]) }
    }

    /// The inline strip on that row's bar: ↩/y deletes, esc/n cancels (`handleConfirmKey`).
    func confirmDelete(ts: String) {
        guard let i = indexOfTS[ts] else { return }
        confirmingTS = ts
        let r = rowOf[i]
        table.scrollRowToVisible(r)
        stillCursor?.cancel()
        let w = hoverBar.beginConfirm()
        placeBar(row: r, width: w)
        hoverBar.isHidden = false
    }

    /// For the key router while the delete strip is up.
    func handleConfirmKey(_ e: NSEvent) -> Bool {
        guard confirmingTS != nil else { return false }
        if e.keyCode == 36 || e.charactersIgnoringModifiers == "y" { finishConfirm(true); return true }
        if e.keyCode == 53 || e.charactersIgnoringModifiers == "n" { finishConfirm(false); return true }
        return false
    }

    /// For the script and checks: put the hover on a message as the mouse would.
    func hover(message i: Int?) {
        guard let i, i >= 0, i < rowOf.count else { hoveredRow = nil; return }
        mouseInside = true
        table.scrollRowToVisible(rowOf[i])
        hoveredRow = rowOf[i]
    }

    // MARK: building

    private var currentWidth: CGFloat {
        let w = scroll.contentView.bounds.width
        return w > 0 ? w : max(bounds.width, 600)
    }

    private func index() {
        rowOf = Array(repeating: 0, count: messages.count)
        indexOfTS = Dictionary(minimumCapacity: messages.count)
        dayRows = []
        unreadRow = nil
        var groupedOf = Array(repeating: false, count: messages.count)
        for (r, it) in items.enumerated() {
            switch it {
            case .message(let i, let g): rowOf[i] = r; groupedOf[i] = g
            case .day: dayRows.append(r)
            case .unread: unreadRow = r
            case .threadReplies: break
            }
        }
        for (i, m) in messages.enumerated() { indexOfTS[m.ts] = i }
        self.groupedOf = groupedOf
    }

    private var groupedOf: [Bool] = []

    /// Reuses every entry whose message didn't change; parses, resolves
    /// names for and builds the rest, in parallel when there are many.
    private func prepareEntries() -> Int {
        var fresh: [Int] = []
        var next: [RowEntry?] = Array(repeating: nil, count: messages.count)
        for (i, m) in messages.enumerated() {
            if let e = cache[m.ts], e.sameBody(m) {
                if e.message != m { e.message = m; e.geo = nil }
                next[i] = e
            } else {
                fresh.append(i)
            }
        }
        if !fresh.isEmpty {
            let ms = messages
            let blocks = Self.parallelMap(fresh.count, empty: [Mrkdwn.Block]()) { k in Mrkdwn.parse(ms[fresh[k]].text) }
            let tp = CACurrentMediaTime()
            let names = resolve(blocks)
            let tr = CACurrentMediaTime()
            // Serial on purpose: attributed-string building contends on AppKit locks and gets slower across threads.
            let bodies = fresh.indices.map { k in Self.body(ms[fresh[k]], blocks[k], names) }
            if Brand.env("TIMING") != nil { print(String(format: "  resolve %.1f bodies %.1f", (tr - tp) * 1000, (CACurrentMediaTime() - tr) * 1000)) }
            for (k, i) in fresh.enumerated() { next[i] = RowEntry(message: ms[i], blocks: blocks[k], body: bodies[k]) }
        }
        entries = next.map { $0! }
        var newCache: [String: RowEntry] = Dictionary(minimumCapacity: entries.count)
        for e in entries { newCache[e.message.ts] = e }
        cache = newCache
        for (i, e) in entries.enumerated() {
            let g = groupedOf[i]
            let last = i + 1 >= entries.count || !groupedOf[i + 1]
            if e.grouped != g || e.lastInGroup != last { e.grouped = g; e.lastInGroup = last; e.geo = nil }
        }
        return fresh.count
    }

    private static func body(_ m: Message, _ blocks: [Mrkdwn.Block], _ names: ResolvedNames) -> Body {
        if let l = m.local, l.kind == .delete {
            return Body(text: NSAttributedString(string: "Deleted · z to undo", attributes: [.font: Theme.Font.body, .foregroundColor: Theme.textMuted, .paragraphStyle: Body.pBody]),
                        mentionsMe: false, links: [])
        }
        if m.isSystem {
            return Body.build(blocks, edited: false, names: names, dim: true)
        }
        return Body.build(blocks, edited: m.edited, names: names)
    }

    private func resolve(_ blocks: [[Mrkdwn.Block]]) -> ResolvedNames {
        var ids: (users: Set<String>, channels: Set<String>, groups: Set<String>) = ([], [], [])
        for b in blocks { Body.ids(b, into: &ids) }
        var n = ResolvedNames(custom: context.customEmoji, me: context.me)
        for u in ids.users { n.users[u] = context.person(u)?.label ?? context.name(u) }
        for c in ids.channels { if let name = context.channelName(c) { n.channels[c] = name } }
        for g in ids.groups { if let h = context.groupHandle(g) { n.groups[g] = h } }
        return n
    }

    /// Below 64 items the thread hop costs more than it saves.
    private static func parallelMap<T>(_ n: Int, empty: T, _ f: (Int) -> T) -> [T] {
        var out = Array(repeating: empty, count: n)
        if n < 64 { for k in 0..<n { out[k] = f(k) }; return out }
        let chunk = 32
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: (n + chunk - 1) / chunk) { c in
                for k in (c * chunk)..<min(n, (c + 1) * chunk) { buf[k] = f(k) }
            }
        }
        return out
    }

    /// Geometry for every entry missing it at `width`: body heights are
    /// measured in parallel, one TextKit stack per worker.
    private func layoutAll(width w: CGFloat) {
        let cw = max(60, w - RowGeometry.content - RowGeometry.gutter)
        let need = entries.indices.filter { entries[$0].bodyHeight?.width != cw }
        if !need.isEmpty {
            let es = entries
            var hs = Array(repeating: CGFloat(0), count: need.count)
            if need.count < 64 {
                let m = Measurer()
                for (k, i) in need.enumerated() { hs[k] = m.height(es[i].body.text, width: cw) }
            } else {
                let chunk = 48
                hs.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: (need.count + chunk - 1) / chunk) { c in
                        let m = Measurer()
                        for k in (c * chunk)..<min(need.count, (c + 1) * chunk) { out[k] = m.height(es[need[k]].body.text, width: cw) }
                    }
                }
            }
            for (k, i) in need.enumerated() { entries[i].bodyHeight = (cw, hs[k]); entries[i].geo = nil }
        }
        for e in entries where e.geo?.width != w { e.geo = geometry(e, width: w) }
    }

    private func geometry(_ e: RowEntry, width w: CGFloat) -> RowGeometry {
        let m = e.message
        let cw = max(60, w - RowGeometry.content - RowGeometry.gutter)
        let top: CGFloat = e.grouped ? 2 : 8
        let bodyTop = top + (e.grouped ? 0 : 22)
        let bodyH = e.bodyHeight?.height ?? Body.lineHeight
        var y = bodyTop + bodyH
        var g = RowGeometry(width: w, height: 0, top: top, bodyTop: bodyTop, bodyHeight: bodyH, pills: [], add: .zero, reactionsTop: 0, reactionsHeight: 0)
        if !m.reactions.isEmpty, m.local?.kind != .delete {
            let l = ReactionStrip.layout(m.reactions, me: context.me, custom: context.customEmoji, width: cw)
            g.pills = l.pills; g.add = l.add; g.reactionsTop = y + 6; g.reactionsHeight = l.height
            y += 6 + l.height
        }
        if !inThread, m.replyCount > 0 { g.threadTop = y + 4; y += 4 + ThreadSummaryView.height }
        if footnote(m) != nil { g.footTop = y + 2; y += 18 }
        let bottom: CGFloat = e.lastInGroup ? 8 : 2
        g.height = max(y + bottom, e.grouped ? 0 : top + RowGeometry.avatar + bottom).rounded(.up)
        return g
    }

    private func footnote(_ m: Message) -> NSAttributedString? {
        guard let l = m.local else { return nil }
        let f = Theme.Font.small
        switch (l.kind, l.state) {
        case (.delete, _): return nil
        case (_, .failed): return NSAttributedString(string: "Not sent: \(l.error ?? "unknown error") · ↩ retry", attributes: [.font: f, .foregroundColor: Theme.unreadRed])
        case (.send, .pending), (.send, .sending): return NSAttributedString(string: "Sending… z to undo", attributes: [.font: f, .foregroundColor: Theme.textFaint])
        case (.edit, .pending), (.edit, .sending): return NSAttributedString(string: "Saving… z to undo", attributes: [.font: f, .foregroundColor: Theme.textFaint])
        default: return nil
        }
    }

    private func mentionsMe(_ e: RowEntry) -> Bool { e.message.mentionsMe || e.body.mentionsMe }
    private func isMine(_ m: Message) -> Bool { m.isMine || (context.me != nil && m.user == context.me) }

    private func contextChanged() {
        guard !messages.isEmpty else { return }
        cache = [:]
        _ = prepareEntries()
        layoutAll(width: width)
        table.reloadData()
    }

    func avatarLoaded(_ id: String) {
        let rows = table.rows(in: table.visibleRect)
        for r in rows.location..<(rows.location + rows.length) where r < items.count {
            guard case .message(let i, false) = items[r], messages[i].user == id || messages[i].botID == id,
                  let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? MessageCellView else { continue }
            let m = messages[i]
            cell.setAvatar(Avatars.shared.layerContents(for: m.botID ?? m.user, name: m.author, url: m.avatar, size: 36))
        }
    }

    // MARK: layout and scroll

    override func layout() {
        super.layout()
        let w = currentWidth
        if w != width, !messages.isEmpty {
            relayout(width: w)
        }
        updateOverlays()
        if editingTS != nil { placeEditor() }
    }

    /// A new width: rows in view first so the frame is right now, the rest
    /// in one deferred pass, keeping the first visible message in place.
    private func relayout(width w: CGFloat) {
        let anchor = scrollAnchor
        let atBottom = isAtBottom
        width = w
        let visible = table.rows(in: scroll.contentView.bounds)
        let cw = max(60, w - RowGeometry.content - RowGeometry.gutter)
        let m = Measurer()
        for r in visible.location..<(visible.location + visible.length) where r < items.count {
            guard case .message(let i, _) = items[r] else { continue }
            let e = entries[i]
            e.bodyHeight = (cw, m.height(e.body.text, width: cw))
            e.geo = geometry(e, width: w)
        }
        let shown = IndexSet(integersIn: visible.location..<(visible.location + visible.length))
        table.noteHeightOfRows(withIndexesChanged: shown)
        table.reloadData(forRowIndexes: shown, columnIndexes: [0])
        deferredRelayout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.width == w else { return }
            let anchor = self.scrollAnchor
            let atBottom = self.isAtBottom
            self.layoutAll(width: w)
            self.table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.items.count))
            let v = self.table.rows(in: self.table.visibleRect)
            self.table.reloadData(forRowIndexes: IndexSet(integersIn: v.location..<(v.location + v.length)), columnIndexes: [0])
            if atBottom { self.scrollToBottom() } else if let anchor { self.restore(anchor) }
            self.updateOverlays()
        }
        deferredRelayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inLiveResize ? 0.25 : 0), execute: work)
        if atBottom { scrollToBottom() } else if let anchor { restore(anchor) }
    }

    private var deferredRelayout: DispatchWorkItem?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if let w = deferredRelayout { w.cancel(); deferredRelayout = nil; DispatchQueue.main.async { w.perform() } }
    }

    var atBottom: Bool { isAtBottom }

    private var isAtBottom: Bool {
        let visible = scroll.contentView.bounds
        return visible.maxY >= table.bounds.height - 4 + scroll.contentInsets.bottom - 1 || table.bounds.height <= visible.height
    }

    private func scrollTo(y: CGFloat) {
        let docH = table.bounds.height
        let maxY = max(-scroll.contentInsets.top, docH - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
        let clamped = max(-scroll.contentInsets.top, min(y, maxY))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func restore(_ a: ScrollAnchor) {
        guard let i = indexOfTS[a.ts] else { return }
        scrollTo(y: table.rect(ofRow: rowOf[i]).minY - CGFloat(a.offset))
    }

    private func firstMessage(after row: Int) -> Int? {
        for r in (row + 1)..<items.count { if case .message(let i, _) = items[r] { return i } }
        return nil
    }

    @objc private func scrolled() {
        let visible = scroll.contentView.bounds
        if visible.minY < 40, !messages.isEmpty { onNearTop?(); actions.nearTop() }
        updateOverlays()
        if mouseInside, let w = window {
            mouse(at: table.convert(w.mouseLocationOutsideOfEventStream, from: nil))
        } else if let h = hoveredRow ?? (confirmingTS.flatMap { indexOfTS[$0] }.map { rowOf[$0] }) {
            placeBar(row: h, width: hoverBar.frame.width)
        }
        if editingTS != nil { placeEditor() }
        watchBottom()
    }

    private func watchBottom() {
        let lastVisible = isAtBottom && !items.isEmpty
        if lastVisible { newWhileScrolledUp = 0 }
        guard lastVisible, window?.isKeyWindow == true else { bottomTimer?.cancel(); bottomTimer = nil; return }
        guard bottomTimer == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bottomTimer = nil
            if self.isAtBottom, self.window?.isKeyWindow == true { self.actions.bottomVisible() }
        }
        bottomTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func updateOverlays() {
        guard !items.isEmpty else {
            for p in [sticky, jumpTop, jumpBottom] { p.setShown(false) }
            return
        }
        let visible = scroll.contentView.bounds
        let top = visible.minY
        // sticky day: the last separator at or above the top edge
        var lo = 0, hi = dayRows.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if table.rect(ofRow: dayRows[mid]).minY <= top + 1 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        if let f = found, case .day(let d) = items[dayRows[f]], table.rect(ofRow: dayRows[f]).minY < top - 1 {
            sticky.label = DayLabel.string(d)
            sticky.place(centerX: bounds.midX, top: 8)
            sticky.setShown(true)
        } else {
            sticky.setShown(false)
        }
        // jump to unread / mentions above the view
        var kind: JumpPill.Kind?
        if let u = unreadRow {
            let mentionsAbove = entries.indices.filter { rowOf[$0] > u && table.rect(ofRow: rowOf[$0]).maxY < top && mentionsMe(entries[$0]) }.count
            if mentionsAbove > 0 { kind = .mentions(mentionsAbove) }
            else if table.rect(ofRow: u).maxY < top { kind = .unread(messages.count - (firstMessage(after: u) ?? messages.count)) }
        }
        if let kind {
            jumpTop.kind = kind
            jumpTop.setFrameOrigin(NSPoint(x: (bounds.midX - jumpTop.frame.width / 2).rounded(), y: sticky.shown ? 42 : 12))
            jumpTop.setShown(true)
        } else {
            jumpTop.setShown(false)
        }
        let fromBottom = table.bounds.height - visible.maxY
        let far = fromBottom > visible.height * 1.5
        let showBottom = far || (newWhileScrolledUp > 0 && fromBottom > 4)
        jumpBottom.kind = .bottom(newCount: newWhileScrolledUp)
        jumpBottom.setFrameOrigin(NSPoint(x: bounds.width - 16 - jumpBottom.frame.width, y: bounds.height - 12 - jumpBottom.frame.height))
        jumpBottom.setShown(showBottom)
    }

    private func jumpTopClicked(_ p: NSPoint) {
        if case .unread = jumpTop.kind, jumpTop.markRect.contains(p) { actions.markRead(); jumpTop.setShown(false); return }
        if case .mentions = jumpTop.kind { jumpToNextMention(); return }
        jumpToUnread()
    }

    private func jumpToDay() {
        guard let i = selected ?? messages.indices.last else { return }
        let day = Calendar.current.startOfDay(for: messages[i].date)
        if let r = dayRows.first(where: { if case .day(let d) = items[$0] { return d == day }; return false }) {
            scrollTo(y: table.rect(ofRow: r).minY)
        }
    }

    // MARK: hover

    private func mouse(at p: NSPoint?) {
        guard let p else {
            mouseInside = false
            if let w = window, hoverBar.frame.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) { return }
            hoveredRow = nil
            return
        }
        mouseInside = true
        stillCursor?.cancel()
        let inBar = !hoverBar.isHidden && hoverBar.frame.contains(convert(p, from: table))
        if !inBar {
            let r = table.row(at: p)
            hoveredRow = r >= 0 && r < items.count && { if case .message = items[r] { return true }; return false }() ? r : nil
        }
        guard let h = hoveredRow, let cell = table.view(atColumn: 0, row: h, makeIfNecessary: false) as? MessageCellView else { return }
        let local = cell.convert(p, from: table)
        cell.thread.hovered = !cell.thread.isHidden && cell.thread.frame.contains(local) && !inBar
        cell.reactions.hover(at: inBar ? nil : table.convert(p, to: nil))
    }

    private func hoverChanged(from old: Int?) {
        if let old, old < items.count { setHover(old, false) }
        if let h = hoveredRow { setHover(h, true) }
        guard confirmingTS == nil else { return }
        if let h = hoveredRow, case .message(let i, _) = items[h], editingTS != messages[i].ts {
            let w = hoverBar.configure(mine: isMine(messages[i]), quick: actions.quickReactions())
            placeBar(row: h, width: w)
            hoverBar.isHidden = false
        } else {
            hoverBar.isHidden = true
            hoverBar.hover(at: nil)
        }
    }

    private func setHover(_ r: Int, _ on: Bool) {
        (table.rowView(atRow: r, makeIfNecessary: false) as? MessageRowView)?.hovered = on
        guard let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? MessageCellView else { return }
        let lit = on || table.selectedRow == r
        cell.showGutterTime = lit
        cell.reactions.showAdd = lit
        if !on { cell.thread.hovered = false; cell.reactions.hover(at: nil) }
    }

    private func placeBar(row r: Int, width w: CGFloat) {
        guard r < items.count else { return }
        let rect = convert(table.rect(ofRow: r), from: table)
        var y = rect.minY - 13
        if y < 4 { y = max(rect.minY, 0) + 4 }
        hoverBar.frame = NSRect(x: bounds.width - 20 - w, y: y, width: w, height: HoverBar.height)
        hoverBar.needsLayout = true
    }

    /// No mouse over the list: the bar comes to the cursor row after it's been still for 400 ms.
    private func cursorMoved() {
        stillCursor?.cancel()
        if !mouseInside, confirmingTS == nil { hoveredRow = nil }
        refreshLit()
        guard !mouseInside else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.mouseInside, self.confirmingTS == nil, let s = self.selected, self.editingTS == nil else { return }
            let r = self.rowOf[s]
            let bw = self.hoverBar.configure(mine: self.isMine(self.messages[s]), quick: self.actions.quickReactions())
            self.placeBar(row: r, width: bw)
            self.hoverBar.isHidden = false
        }
        stillCursor = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func refreshLit() {
        let rows = table.rows(in: table.visibleRect)
        for r in rows.location..<(rows.location + rows.length) {
            guard let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? MessageCellView else { continue }
            let lit = r == hoveredRow || r == table.selectedRow
            cell.showGutterTime = lit
            cell.reactions.showAdd = lit
        }
    }

    private var barMessage: Message? {
        if let ts = confirmingTS, let i = indexOfTS[ts] { return messages[i] }
        if let h = hoveredRow, h < items.count, case .message(let i, _) = items[h] { return messages[i] }
        return selectedMessage
    }

    private func barAction(_ a: HoverBar.Action) {
        guard let m = barMessage else { return }
        switch a {
        case .react: actions.react(m)
        case .quick(let name): actions.toggleReaction(m, name)
        case .reply: actions.reply(m)
        case .share: actions.copyLink(m)
        case .save: actions.save(m)
        case .edit: actions.edit(m)
        case .delete: confirmDelete(ts: m.ts)
        case .more: actions.more(m)
        }
    }

    private func finishConfirm(_ yes: Bool) {
        guard let ts = confirmingTS else { return }
        confirmingTS = nil
        hoverBar.endConfirm()
        hoverBar.isHidden = true
        if yes, let i = indexOfTS[ts] { actions.delete(messages[i]) }
        let h = hoveredRow
        hoveredRow = nil
        hoveredRow = h
    }

    // MARK: editing

    private func makeEditor() -> InlineEditor {
        let e = InlineEditor(textView: makeEditorTextView())
        e.onSave = { [weak self] m, text in
            self?.actions.saveEdit(m, text)
            self?.cancelEdit()
        }
        e.onCancel = { [weak self] in self?.cancelEdit() }
        e.onHeight = { [weak self] in self?.editorResized() }
        table.addSubview(e)
        return e
    }

    private func editorResized() {
        guard let ts = editingTS, let i = indexOfTS[ts] else { return }
        let h = editor.height(width: entries[i].geo?.contentWidth ?? 300)
        guard h != editorHeight else { return }
        editorHeight = h
        table.noteHeightOfRows(withIndexesChanged: [rowOf[i]])
        placeEditor()
    }

    private func placeEditor() {
        guard let ts = editingTS, let i = indexOfTS[ts], let g = entries[i].geo else { return }
        let rect = table.rect(ofRow: rowOf[i])
        editor.frame = NSRect(x: RowGeometry.content, y: rect.minY + g.bodyTop, width: g.contentWidth, height: editorHeight)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .message(let i, _):
            let e = entries[i]
            guard let g = e.geo else { return 40 }
            if e.message.ts == editingTS { return g.bodyTop + editorHeight + (e.lastInGroup ? 8 : 4) }
            return g.height
        case .day: return DayCellView.height
        case .unread: return UnreadCellView.height
        case .threadReplies: return ThreadDividerCellView.height
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .message = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = (tableView.makeView(withIdentifier: MessageRowView.id, owner: self) as? MessageRowView) ?? MessageRowView()
        r.dim = !focused
        r.hovered = row == hoveredRow
        if case .message(let i, _) = items[row] {
            r.mentionsMe = mentionsMe(entries[i]) && editingTS != messages[i].ts
            r.editing = editingTS == messages[i].ts
        } else {
            r.mentionsMe = false
            r.editing = false
        }
        return r
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let t0 = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - t0) * 1000
            if ms > 8 { log(String(format: "slow row %d: viewFor %.1f ms", row, ms)) }
        }
        switch items[row] {
        case .day(let d):
            let v = (tableView.makeView(withIdentifier: DayCellView.id, owner: self) as? DayCellView) ?? DayCellView()
            v.label = DayLabel.string(d)
            return v
        case .unread:
            return (tableView.makeView(withIdentifier: UnreadCellView.id, owner: self) as? UnreadCellView) ?? UnreadCellView()
        case .threadReplies(let n):
            let v = (tableView.makeView(withIdentifier: ThreadDividerCellView.id, owner: self) as? ThreadDividerCellView) ?? ThreadDividerCellView()
            v.count = n
            return v
        case .message(let i, let grouped):
            let cell = (tableView.makeView(withIdentifier: MessageCellView.id, owner: self) as? MessageCellView) ?? MessageCellView()
            configure(cell, i, grouped: grouped, row: row)
            return cell
        }
    }

    private func configure(_ cell: MessageCellView, _ i: Int, grouped: Bool, row: Int) {
        let e = entries[i]
        let m = e.message
        guard let g = e.geo else { return }
        let header = grouped ? nil : MessageCellView.Header(author: m.author.isEmpty ? m.user : m.author, bot: m.isBot,
                                                           time: TimeLabel.short(m.date), tooltip: TimeLabel.tooltip(m.date))
        let avatar = grouped ? nil : Avatars.shared.layerContents(for: m.botID ?? m.user, name: m.author, url: m.avatar, size: 36)
        var thread: ThreadSummaryView.Model?
        if !inThread, m.replyCount > 0 {
            let repliers = m.replyUsers.prefix(3).map { id in (id: id, name: context.person(id)?.label ?? context.name(id), url: context.person(id)?.image48) }
            thread = .init(count: m.replyCount, latest: m.latestReply.flatMap(Double.init).map { Date(timeIntervalSince1970: $0) },
                           repliers: repliers, draft: context.draftThreads.contains(m.ts), unread: context.threadUnread(m.ts))
        }
        let pending = m.local.map { $0.state == .pending || $0.state == .sending } ?? false
        cell.configure(body: e.body.text, header: header, gutter: grouped ? TimeLabel.gutter(m.date) : nil, avatar: avatar, bot: m.isBot,
                       geo: g, thread: thread, foot: footnote(m), alpha: pending ? 0.55 : 1)
        let editing = m.ts == editingTS
        cell.body.isHidden = editing
        cell.reactions.isHidden = editing || g.pills.isEmpty
        cell.thread.isHidden = editing || thread == nil
        cell.toolTip = grouped ? TimeLabel.tooltip(m.date) : nil
        let lit = row == hoveredRow || row == table.selectedRow
        cell.showGutterTime = lit
        cell.reactions.showAdd = lit
        cell.reactions.name = context.name
        let ts = m.ts
        cell.body.onLink = { [weak self, weak cell] url, rect in
            guard let self, let cell else { return }
            self.open(url, rect: self.convert(rect, from: cell.body))
        }
        cell.body.onMouseDown = { [weak self] in if let self, let i = self.indexOfTS[ts] { self.select(i) } }
        cell.reactions.onToggle = { [weak self] name in if let self, let i = self.indexOfTS[ts] { self.actions.toggleReaction(self.messages[i], name) } }
        cell.reactions.onAdd = { [weak self] in if let self, let i = self.indexOfTS[ts] { self.actions.react(self.messages[i]) } }
        cell.thread.onOpen = { [weak self] in if let self, let i = self.indexOfTS[ts] { self.actions.openThread(self.messages[i]) } }
    }

    private func open(_ url: URL, rect: NSRect) {
        let s = url.absoluteString
        if s.hasPrefix("relay-user:") {
            actions.openUser(String(s.dropFirst(11)), rect)
        } else if s.hasPrefix("relay-channel:") {
            actions.openChannel(String(s.dropFirst(14)))
        } else if s.hasPrefix("relay-") {
            return
        } else {
            actions.openURL(url, NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        }
    }

    private func selectRow(_ i: Int) {
        guard i >= 0, i < rowOf.count else { return }
        table.selectRowIndexes([rowOf[i]], byExtendingSelection: false)
    }

    private func updateSelectionStyle() {
        table.enumerateAvailableRowViews { row, _ in (row as? MessageRowView)?.dim = !self.focused }
    }

    @objc private func clicked() {
        let r = table.clickedRow
        guard r >= 0, r < items.count, case .message(let i, _) = items[r] else { return }
        select(i)
        if let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? MessageCellView, let e = NSApp.currentEvent {
            let p = cell.convert(e.locationInWindow, from: nil)
            if cell.authorRects.contains(where: { $0.contains(p) }) {
                actions.openUser(messages[i].user, convert(cell.authorRects[1], from: cell))
            }
        }
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard r >= 0, r < items.count, case .message(let i, _) = items[r] else { return }
        onOpen?(i)
    }
}
