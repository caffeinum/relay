import AppKit
import RelayCore

/// The sidebar (D§3): workspace header, the find field, Threads / Mentions /
/// Drafts, then the groups from `Sections.place`. One table, a recycled
/// cell and row view per kind, everything drawn, one tracking area.
final class Sidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let width: CGFloat = 260

    enum Top: String { case threads = "Threads", mentions = "Mentions", drafts = "Drafts" }
    enum Row: Equatable {
        case top(Top), separator, spacer, header(SidebarGroup), conv(Conversation)
        var id: NSUserInterfaceItemIdentifier {
            switch self {
            case .top: return .init("sbTop")
            case .separator: return .init("sbSep")
            case .spacer: return .init("sbSpace")
            case .header: return .init("sbHeader")
            case .conv: return .init("sbConv")
            }
        }
        var height: CGFloat {
            switch self {
            case .separator: return 17
            case .spacer: return 10
            default: return 28
            }
        }
    }

    private(set) var rows: [Row] = []
    private var groups: [SidebarGroup] = []
    private var all: [Conversation] = []
    private(set) var current: String?
    private var table: SidebarTable!
    private var scroll: NSScrollView!
    let header = SidebarHeader()
    let find = FindField()
    private let pill = SidebarPill()
    private var hovered: Int? { didSet { if hovered != oldValue { [oldValue, hovered].compactMap { $0 }.forEach(redraw) } } }
    var draftCount = 0 { didSet { if draftCount != oldValue, let i = rows.firstIndex(of: .top(.drafts)) { redraw(i) } } }

    var onSelect: ((Conversation) -> Void)?
    var onTop: ((Top) -> Void)?
    var onToggle: ((String) -> Void)?
    var onHeaderMenu: ((SidebarGroup, NSView, NSPoint) -> Void)?
    var avatar: (Conversation) -> (id: String, url: String?) = { ($0.userID ?? $0.id, nil) }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.sbBg.cgColor }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let t = SidebarTable()
        let col = NSTableColumn(identifier: .init("c"))
        col.resizingMask = .autoresizingMask
        t.addTableColumn(col)
        t.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        t.headerView = nil
        t.intercellSpacing = .zero
        t.style = .plain
        t.backgroundColor = .clear
        t.selectionHighlightStyle = .none
        t.dataSource = self
        t.delegate = self
        t.refusesFirstResponder = true
        t.target = self
        t.action = #selector(clicked)
        t.onMouse = { [weak self] p in self?.mouse(p) }
        let s = NSScrollView()
        s.documentView = t
        s.drawsBackground = false
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.scrollerStyle = .overlay
        table = t
        scroll = s
        find.delegate = self
        for v in [header, find, s, pill] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 52),
            find.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 0), find.heightAnchor.constraint(equalToConstant: 30),
            find.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), find.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            s.topAnchor.constraint(equalTo: find.bottomAnchor, constant: 8), s.bottomAnchor.constraint(equalTo: bottomAnchor),
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.centerXAnchor.constraint(equalTo: centerXAnchor), pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            pill.heightAnchor.constraint(equalToConstant: 28),
        ])
        pill.onClick = { [weak self] in self?.revealNextUnread() }
        s.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: s.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(symbolsReady), name: Symbols.warmed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    var workspace: String { get { header.name } set { header.name = newValue } }
    var status: String? { get { header.status } set { header.status = newValue } }

    /// Every conversation in sidebar order (the order ⌥↑/⌥↓ walks).
    var conversations: [Conversation] { rows.compactMap { if case .conv(let c) = $0 { return c }; return nil } }
    var allConversations: [Conversation] { all }

    func show(_ convs: [Conversation], groups: [SidebarGroup], current: String?) {
        all = convs
        self.groups = groups
        self.current = current
        rebuild()
    }

    func select(_ id: String?) {
        guard id != current else { return }
        let old = current
        current = id
        for (i, r) in rows.enumerated() { if case .conv(let c) = r, c.id == old || c.id == id { redraw(i) } }
        if let id, let i = rows.firstIndex(where: { if case .conv(let c) = $0 { return c.id == id }; return false }) { table.scrollRowToVisible(i) }
    }

    private func rebuild() {
        var out: [Row] = []
        let q = find.stringValue.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let f = Fuzzy(all.map(\.name))
            out = f.rank(q, limit: 50).map { .conv(all[$0.0]) }
        } else {
            out = [.top(.threads), .top(.mentions), .top(.drafts), .separator]
            for (k, g) in groups.enumerated() {
                if k > 0 { out.append(.spacer) }
                out.append(.header(g))
                out += g.rows.map { .conv($0) }
            }
        }
        rows = out
        if let h = hovered, h >= rows.count { hovered = nil }
        table.reloadData()
        if !q.isEmpty, let first = conversations.first { filterPick = first.id } else { filterPick = nil }
        updatePill()
    }

    /// Next / previous conversation in sidebar order, wrapping off neither end.
    func neighbour(_ d: Int, unreadOnly: Bool = false) -> Conversation? {
        let cs = conversations
        guard let i = cs.firstIndex(where: { $0.id == current }) else { return cs.first { !unreadOnly || $0.unread > 0 } }
        var j = i + d
        while cs.indices.contains(j) {
            if !unreadOnly || cs[j].unread > 0 || cs[j].mentions > 0 { return cs[j] }
            j += d
        }
        return nil
    }

    // MARK: find field (D§3.2)

    private var filterPick: String? { didSet { if filterPick != oldValue { table.reloadData() } } }

    func focusFind() { window?.makeFirstResponder(find) }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let cs = conversations
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let d = sel == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let i = cs.firstIndex { $0.id == filterPick } ?? -1
            if cs.indices.contains(i + d) { filterPick = cs[i + d].id; table.scrollRowToVisible(i + d) }
        case #selector(NSResponder.insertNewline(_:)):
            if let id = filterPick, let c = cs.first(where: { $0.id == id }) { clearFind(); onSelect?(c) }
        case #selector(NSResponder.cancelOperation(_:)):
            clearFind()
        default:
            return false
        }
        return true
    }

    func clearFind() {
        find.stringValue = ""
        rebuild()
        window?.makeFirstResponder(nil)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = (tableView.makeView(withIdentifier: SidebarRowView.id, owner: self) as? SidebarRowView) ?? SidebarRowView()
        r.identifier = SidebarRowView.id
        style(r, row)
        return r
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = rows[row].id
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SidebarCell) ?? SidebarCell()
        cell.identifier = id
        configure(cell, row)
        return cell
    }

    private func isSelected(_ row: Int) -> Bool {
        guard case .conv(let c) = rows[row] else { return false }
        return c.id == (filterPick ?? current)
    }

    private func style(_ r: SidebarRowView, _ row: Int) {
        r.selectedFill = isSelected(row)
        r.hoverFill = row == hovered && !r.selectedFill && { if case .conv = rows[row] { return true }; if case .top = rows[row] { return true }; return false }()
    }

    private func configure(_ cell: SidebarCell, _ row: Int) {
        var model = SidebarCell.Model.empty
        switch rows[row] {
        case .top(let t): model = .top(t, count: t == .drafts ? draftCount : 0)
        case .separator: model = .separator
        case .spacer: model = .empty
        case .header(let g): model = .header(g, hovered: row == hovered)
        case .conv(let c):
            let a = c.isDM && c.kind == .im ? avatar(c) : nil
            model = .conv(c, selected: isSelected(row), avatar: a.map { Avatars.shared.layerContents(for: $0.id, name: c.name, url: $0.url, size: 16) })
        }
        cell.model = model
    }

    private func redraw(_ i: Int) {
        guard i < rows.count else { return }
        if let r = table.rowView(atRow: i, makeIfNecessary: false) as? SidebarRowView { style(r, i) }
        if let c = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? SidebarCell { configure(c, i) }
    }

    func reloadAvatar(_ id: String) {
        for (i, r) in rows.enumerated() { if case .conv(let c) = r, c.userID == id { redraw(i) } }
    }

    @objc private func symbolsReady() {
        let v = table.rows(in: table.visibleRect)
        for i in v.location..<(v.location + v.length) { redraw(i) }
    }

    private func mouse(_ p: NSPoint?) {
        guard let p else { hovered = nil; return }
        let r = table.row(at: p)
        hovered = r >= 0 ? r : nil
    }

    @objc private func clicked() {
        let r = table.clickedRow
        guard r >= 0, r < rows.count else { return }
        switch rows[r] {
        case .conv(let c): if !find.stringValue.isEmpty { clearFind() }; onSelect?(c)
        case .top(let t): onTop?(t)
        case .header(let g):
            let p = table.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil)
            let rect = table.rect(ofRow: r)
            if p.x > rect.maxX - 36, let onHeaderMenu { onHeaderMenu(g, table, NSPoint(x: rect.maxX - 30, y: rect.maxY)) } else { onToggle?(g.id) }
        default: break
        }
    }

    // MARK: floating pill (D§3.6)

    @objc private func scrolled() { updatePill() }

    private func unreadRows() -> [(row: Int, mention: Bool)] {
        rows.enumerated().compactMap { i, r in
            guard case .conv(let c) = r, c.id != current, c.unread > 0 || c.mentions > 0 else { return nil }
            return (i, c.mentions > 0)
        }
    }

    private func updatePill() {
        let visible = scroll.contentView.bounds
        let below = unreadRows().filter { table.rect(ofRow: $0.row).minY > visible.maxY - 4 }
        guard !below.isEmpty, find.stringValue.isEmpty else { pill.setShown(false); return }
        pill.title = below.contains { $0.mention } ? "Unread mentions" : "More unreads"
        pill.setShown(true)
    }

    private func revealNextUnread() {
        let visible = scroll.contentView.bounds
        let below = unreadRows().filter { table.rect(ofRow: $0.row).minY > visible.maxY - 4 }
        guard let target = below.first(where: { $0.mention }) ?? below.first else { return }
        table.scrollRowToVisible(target.row)
    }
}

final class SidebarTable: NSTableView {
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
}

final class SidebarRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("sbRow")
    var selectedFill = false { didSet { if selectedFill != oldValue { needsDisplay = true } } }
    var hoverFill = false { didSet { if hoverFill != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        guard selectedFill || hoverFill else { return }
        (selectedFill ? Theme.sbSelectedBg : Theme.sbHover).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

/// One drawn row of any kind; nothing inside is a subview.
final class SidebarCell: NSView {
    enum Model {
        case empty, separator
        case top(Sidebar.Top, count: Int)
        case header(SidebarGroup, hovered: Bool)
        case conv(Conversation, selected: Bool, avatar: CGImage?)
    }

    var model: Model = .empty { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    private func drawLabel(_ a: NSAttributedString, x: CGFloat, maxX: CGFloat) {
        let h = a.size().height
        a.draw(with: NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, maxX - x), height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor, in r: NSRect, fallback: String? = nil) {
        if Symbols.ready { Symbols.draw(name, size, weight, color: color, in: r); return }
        guard let fallback else { return }
        let a = Self.text(fallback, .systemFont(ofSize: size), color)
        let s = a.size()
        a.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        switch model {
        case .empty: break
        case .separator:
            Theme.sbSeparator.setFill()
            NSRect(x: 12, y: 8, width: w - 24, height: 1).fill()
        case .top(let t, let count):
            let sym = t == .threads ? "bubble.left.and.text.bubble.right" : t == .mentions ? "at" : "paperplane"
            symbol(sym, 13, .regular, Theme.sbText, in: NSRect(x: 12, y: 6, width: 16, height: 16), fallback: t == .mentions ? "@" : nil)
            var maxX = w - 12
            if t == .drafts, count > 0 {
                let n = Self.text("\(count)", Theme.Font.small, Theme.sbText)
                let s = n.size()
                n.draw(at: NSPoint(x: w - 20 - s.width, y: (bounds.height - s.height) / 2))
                symbol("pencil", 11, .regular, Theme.sbText, in: NSRect(x: w - 36 - s.width, y: 6, width: 14, height: 16), fallback: "✎")
                maxX = w - 40 - s.width
            }
            drawLabel(Self.text(t.rawValue, Theme.Font.sbRow, Theme.sbText), x: 36, maxX: maxX)
        case .header(let g, let hovered):
            let chev = NSRect(x: 12, y: 9, width: 10, height: 10)
            if g.collapsed {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: chev.midX - 1.5, y: chev.midY - 3.5)); p.line(to: NSPoint(x: chev.midX + 2, y: chev.midY)); p.line(to: NSPoint(x: chev.midX - 1.5, y: chev.midY + 3.5))
                p.lineWidth = 1.5; p.lineCapStyle = .round; p.lineJoinStyle = .round
                Theme.sbText.setStroke(); p.stroke()
            } else {
                Glyphs.chevronDown(in: chev, Theme.sbText)
            }
            var x: CGFloat = 26
            if let icon = g.icon {
                let r = NSRect(x: 26, y: 6, width: 16, height: 16)
                if icon.unicodeScalars.first.map({ $0.properties.isEmojiPresentation || $0.value > 0x2000 }) == true {
                    let a = Self.text(icon, .systemFont(ofSize: 13), Theme.sbText)
                    let s = a.size()
                    a.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
                } else {
                    symbol(icon, 13, .regular, Theme.sbText, in: r, fallback: icon == "star" ? "☆" : nil)
                }
                x = 46
            }
            let label = g.collapsed && g.hidden > 0 ? "\(g.name)" : g.name
            drawLabel(Self.text(label, Theme.Font.sbHeader, Theme.sbText), x: x, maxX: w - (hovered ? 40 : 12))
            if hovered { symbol("ellipsis", 12, .regular, Theme.sbText, in: NSRect(x: w - 36, y: 6, width: 16, height: 16), fallback: "…") }
        case .conv(let c, let selected, let avatar):
            let unread = c.unread > 0 || c.mentions > 0
            let fg = selected ? Theme.sbSelectedText : unread ? Theme.sbTextUnread : Theme.sbText
            let glyph = NSRect(x: 26, y: 6, width: 16, height: 16)
            switch c.kind {
            case .channel:
                let a = Self.text("#", .systemFont(ofSize: 15, weight: unread ? .semibold : .regular), fg)
                let s = a.size()
                a.draw(at: NSPoint(x: glyph.midX - s.width / 2, y: glyph.midY - s.height / 2))
            case .private: Glyphs.lock(in: glyph, fg)
            case .mpim: symbol("person.2.fill", 10, .regular, fg, in: glyph, fallback: "●")
            case .im:
                if let avatar, let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    let r = glyph
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: c.userIsBot ? 4 : 3, cornerHeight: c.userIsBot ? 4 : 3, transform: nil))
                    ctx.clip()
                    ctx.translateBy(x: 0, y: r.maxY + r.minY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(avatar, in: r)
                    ctx.restoreGState()
                }
            }
            var maxX = w - 12 - 8
            if c.mentions > 0 {
                let n = Self.text("\(c.mentions)", Theme.Font.badge, .white)
                let s = n.size()
                let pw = max(18, s.width + 12)
                let r = NSRect(x: w - 20 - pw, y: 5, width: pw, height: 18)
                Theme.sbBadge.setFill()
                NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
                n.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
                maxX = r.minX - 6
            } else if c.hasDraft {
                symbol("pencil", 11, .regular, fg, in: NSRect(x: w - 36, y: 6, width: 16, height: 16), fallback: "✎")
                maxX = w - 40
            }
            let name = Self.text(c.kind == .channel || c.kind == .private ? c.name : c.name, unread ? Theme.Font.sbRowUnread : Theme.Font.sbRow, fg)
            if c.isSelf {
                let m = NSMutableAttributedString(attributedString: name)
                m.append(Self.text("  you", Theme.Font.sbRow, fg.withAlphaComponent(0.7)))
                drawLabel(m, x: 48, maxX: maxX)
            } else {
                drawLabel(name, x: 48, maxX: maxX)
            }
        }
    }
}

/// D§3.1: the workspace name with a chevron, the compose button, and a sync
/// status line only while there's something to say.
final class SidebarHeader: NSView {
    var name = "" { didSet { needsDisplay = true } }
    var status: String? { didSet { needsDisplay = true } }
    var onName: (() -> Void)?
    var onCompose: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        NotificationCenter.default.addObserver(forName: Symbols.warmed, object: nil, queue: .main) { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var composeRect: NSRect { NSRect(x: bounds.width - 40, y: status == nil ? 12 : 6, width: 28, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let a = NSAttributedString(string: name, attributes: [.font: Theme.Font.title, .foregroundColor: Theme.sbTextUnread])
        let s = a.size()
        let y: CGFloat = status == nil ? (bounds.height - s.height) / 2 : 8
        let maxW = bounds.width - 16 - 60
        a.draw(with: NSRect(x: 16, y: y, width: min(s.width, maxW), height: s.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        Glyphs.chevronDown(in: NSRect(x: 16 + min(s.width, maxW) + 6, y: y + s.height / 2 - 5, width: 10, height: 10), Theme.sbTextUnread)
        if let status {
            let t = NSAttributedString(string: status, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.sbText])
            t.draw(with: NSRect(x: 16, y: y + s.height + 1, width: bounds.width - 32, height: 14), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if Symbols.ready { Symbols.draw("square.and.pencil", 15, .regular, color: Theme.sbTextUnread, in: composeRect) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if composeRect.contains(p) { onCompose?() } else { onName?() }
    }
}

/// D§3.2: a plain field drawn as the screenshot's rounded box.
final class FindField: NSTextField {
    override class var cellClass: AnyClass? { get { FindFieldCell.self } set {} }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = Theme.Font.field
        textColor = Theme.sbTextUnread
        placeholderAttributedString = NSAttributedString(string: "Find a conversation…", attributes: [.font: Theme.Font.field, .foregroundColor: Theme.sbText.withAlphaComponent(0.7)])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let focused = currentEditor() != nil
        let r = bounds.insetBy(dx: focused ? 1 : 0.5, dy: focused ? 1 : 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        Theme.sbFieldBg.setFill(); p.fill()
        (focused ? Theme.sbFieldFocus : Theme.sbFieldBorder).setStroke()
        p.lineWidth = focused ? 2 : 1
        p.stroke()
        Glyphs.magnifier(in: NSRect(x: 8, y: (bounds.height - 13) / 2, width: 13, height: 13), Theme.sbText)
        super.draw(dirtyRect)
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
}

final class FindFieldCell: NSTextFieldCell {
    private func inset(_ r: NSRect) -> NSRect {
        let h = (font?.ascender ?? 10) - (font?.descender ?? -3) + 2
        return NSRect(x: r.minX + 28, y: r.minY + (r.height - h) / 2, width: r.width - 36, height: h)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { inset(rect) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: inset(rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) { super.drawInterior(withFrame: cellFrame, in: controlView) }
}

/// D§3.6: "↓ Unread mentions" floating over the bottom of the list.
final class SidebarPill: NSView {
    var title = "" { didSet { if title != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var onClick: (() -> Void)?
    private(set) var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private var label: NSAttributedString { NSAttributedString(string: "↓  " + title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]) }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.size().width) + 28, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.accentPill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        let s = label.size()
        label.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }

    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        if on { isHidden = false }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; animator().alphaValue = on ? 1 : 0 }) { [weak self] in if self?.shown == false { self?.isHidden = true } }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
