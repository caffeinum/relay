import AppKit
import RelayCore

/// ⌘K (D§10, product §13): one field over sectioned results. Static
/// sections are ranked in memory by `Fuzzy` (built once when it opens);
/// dynamic ones (fts, emoji, typed URLs) are asked per query, and the slow
/// ones answer off main. Rows recycle per kind.
final class Palette: Overlay, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Icon { case symbol(String), text(String), avatar(id: String, name: String, url: String?), none }

    struct Item {
        var icon: Icon
        var title: String
        var detail: String = ""
        var keys: [String] = []
        var bold = false
        var badge: Int = 0
        var keep = false                 // runs without closing the palette
        var run: () -> Void
        var alt: (() -> Void)? = nil     // ⌘↩
        var match: String? = nil         // what the fuzzy ranks; default title + detail
    }

    struct Section {
        var title: String
        var prefix: Character?
        var items: [Item] = []
        var emptyQuery: [Item]? = nil    // shown when nothing is typed; nil hides the section then
        var cap = 5
        var dynamic: ((String) -> [Item])? = nil
        var slow: ((String, @escaping ([Item]) -> Void) -> Void)? = nil
        fileprivate var fuzzy: Fuzzy? = nil
    }

    private enum Row { case header(String), item(Item) }

    let field = NSTextField()
    private var table: NSTableView!
    private var scroll: NSScrollView!
    private var scrollHeight: NSLayoutConstraint!
    private var sections: [Section]
    private var rows: [Row] = []
    private var generation = 0
    private var slowResults: [Int: [Item]] = [:]
    private let footer = NSTextField(labelWithString: "↑↓ navigate    ↩ open    ⌘↩ alt action    esc close")
    var onOpenTimed: ((Double) -> Void)?

    init(placeholder: String, sections: [Section], query: String = "") {
        self.sections = sections
        super.init(width: 640, top: 72)
        for i in self.sections.indices where self.sections[i].dynamic == nil && self.sections[i].slow == nil {
            self.sections[i].fuzzy = Fuzzy(self.sections[i].items.map { $0.match ?? ($0.title + " " + $0.detail) })
        }
        card.layer?.backgroundColor = Theme.bgRaised.cgColor
        card.layer?.borderColor = Theme.border.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.35
        card.layer?.shadowRadius = 24
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: Theme.textMuted])
        field.font = .systemFont(ofSize: 17)
        field.textColor = Theme.textStrong
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self
        field.stringValue = query
        let t = NSTableView()
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
        table = t
        let s = NSScrollView()
        s.documentView = t
        s.drawsBackground = false
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        scroll = s
        let line = NSView(); line.wantsLayer = true; line.layer?.backgroundColor = Theme.border.cgColor
        let line2 = NSView(); line2.wantsLayer = true; line2.layer?.backgroundColor = Theme.border.cgColor
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Theme.textMuted
        let glass = GlyphView { r in Glyphs.magnifier(in: NSRect(x: r.minX, y: r.minY, width: 15, height: 15), Theme.textMuted) }
        for v in [glass, field, line, s, line2, footer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(v) }
        scrollHeight = s.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18), glass.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 16), glass.heightAnchor.constraint(equalToConstant: 16),
            field.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 44),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            line.topAnchor.constraint(equalTo: card.topAnchor, constant: 52), line.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: card.leadingAnchor), line.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            s.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 4),
            s.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6), s.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            scrollHeight,
            line2.topAnchor.constraint(equalTo: s.bottomAnchor, constant: 4), line2.heightAnchor.constraint(equalToConstant: 1),
            line2.leadingAnchor.constraint(equalTo: card.leadingAnchor), line2.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.topAnchor.constraint(equalTo: line2.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        refilter()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        window?.makeFirstResponder(field)
        if let ed = field.currentEditor() { ed.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0) }
    }

    func controlTextDidChange(_ obj: Notification) { refilter() }

    var query: String { field.stringValue }

    /// Re-ranks every section; the slow ones answer 120 ms later.
    func refilter() {
        let t0 = CACurrentMediaTime()
        generation += 1
        slowResults = [:]
        var q = field.stringValue.trimmingCharacters(in: .whitespaces)
        var only: Character?
        if let f = q.first, sections.contains(where: { $0.prefix == f }) { only = f; q = String(q.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let gen = generation
        for (i, s) in sections.enumerated() where s.slow != nil && (only == nil || s.prefix == only) && !q.isEmpty {
            let query = q
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.generation == gen else { return }
                s.slow?(query) { items in
                    guard self.generation == gen else { return }
                    self.slowResults[i] = items
                    self.render(q: query, only: only, keepSelection: true)
                }
            }
        }
        render(q: q, only: only, keepSelection: false)
        onOpenTimed?((CACurrentMediaTime() - t0) * 1000)
    }

    private func render(q: String, only: Character?, keepSelection: Bool) {
        let prevSelected = table.selectedRow
        var out: [Row] = []
        for (i, s) in sections.enumerated() {
            if let only, s.prefix != only { continue }
            if only == nil, s.dynamic != nil, s.prefix != nil { continue }
            var items: [Item]
            if let d = s.dynamic {
                items = d(q)
            } else if s.slow != nil {
                items = slowResults[i] ?? []
            } else if q.isEmpty {
                items = only != nil ? s.items : (s.emptyQuery ?? [])
            } else {
                items = (s.fuzzy?.rank(q, limit: only != nil ? 50 : s.cap) ?? []).map { s.items[$0.0] }
            }
            if q.isEmpty, only == nil, s.dynamic == nil { items = Array(items.prefix(s.emptyQuery?.count ?? 0)) }
            guard !items.isEmpty else { continue }
            out.append(.header(s.title.uppercased()))
            out += items.map { .item($0) }
        }
        rows = out
        table.reloadData()
        let firstItem = rows.firstIndex { if case .item = $0 { return true }; return false }
        if keepSelection, prevSelected >= 0, prevSelected < rows.count, case .item = rows[prevSelected] {
            table.selectRowIndexes([prevSelected], byExtendingSelection: false)
        } else if let firstItem {
            table.selectRowIndexes([firstItem], byExtendingSelection: false)
        }
        let h = rows.reduce(CGFloat(0)) { $0 + rowHeight($1) }
        scrollHeight.constant = min(420, max(36, h))
    }

    private func rowHeight(_ r: Row) -> CGFloat { if case .header = r { return 26 }; return 36 }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)):
            pick(table.selectedRow, alt: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        case #selector(NSResponder.cancelOperation(_:)): onClose?()
        default: return false
        }
        return true
    }

    override func handle(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command), e.keyCode == 36 { pick(table.selectedRow, alt: true); return true }
        guard e.modifierFlags.contains(.control) else { return false }
        switch e.charactersIgnoringModifiers {
        case "n": move(1); return true
        case "p": move(-1); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        var i = table.selectedRow
        repeat { i += d } while i >= 0 && i < rows.count && { if case .header = rows[i] { return true }; return false }()
        guard i >= 0, i < rows.count else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    private func pick(_ i: Int, alt: Bool) {
        guard i >= 0, i < rows.count, case .item(let it) = rows[i] else { return }
        let run = alt ? (it.alt ?? it.run) : it.run
        if !it.keep { onClose?() }
        run()
    }

    @objc private func clicked() { pick(table.clickedRow, alt: false) }

    var itemTitles: [String] { rows.compactMap { if case .item(let i) = $0 { return i.title }; return nil } }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight(rows[row]) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .item = rows[row] { return true }; return false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        (tableView.makeView(withIdentifier: PaletteRowView.id, owner: self) as? PaletteRowView) ?? PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: PaletteCell.id, owner: self) as? PaletteCell) ?? PaletteCell()
        switch rows[row] {
        case .header(let t): cell.model = .header(t)
        case .item(let it): cell.model = .item(it)
        }
        return cell
    }
}

final class PaletteRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("palRow")
    override init(frame: NSRect) { super.init(frame: frame); identifier = Self.id }
    required init?(coder: NSCoder) { fatalError() }
    override var isEmphasized: Bool { get { true } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 1)
        Theme.cursorTint.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        Theme.cursor.setFill()
        NSRect(x: r.minX, y: r.minY + 6, width: 2, height: r.height - 12).fill()
    }
}

final class PaletteCell: NSView {
    static let id = NSUserInterfaceItemIdentifier("palCell")
    enum Model { case header(String), item(Palette.Item), none }
    var model: Model = .none { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        switch model {
        case .none: break
        case .header(let t):
            let a = NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Theme.textMuted, .kern: 0.5])
            a.draw(at: NSPoint(x: 12, y: bounds.height - a.size().height - 4))
        case .item(let it):
            let icon = NSRect(x: 8, y: (bounds.height - 20) / 2, width: 20, height: 20)
            switch it.icon {
            case .symbol(let s):
                if Symbols.ready { Symbols.draw(s, 14, color: Theme.textMuted, in: icon) }
            case .text(let s):
                let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: s.unicodeScalars.first!.value < 128 ? 15 : 16, weight: .medium), .foregroundColor: Theme.textMuted])
                let sz = a.size()
                a.draw(at: NSPoint(x: icon.midX - sz.width / 2, y: icon.midY - sz.height / 2))
            case .avatar(let id, let name, let url):
                if let ctx = NSGraphicsContext.current?.cgContext {
                    let img = Avatars.shared.layerContents(for: id, name: name, url: url, size: 20)
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: icon, cornerWidth: 4, cornerHeight: 4, transform: nil))
                    ctx.clip()
                    ctx.translateBy(x: 0, y: icon.maxY + icon.minY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(img, in: icon)
                    ctx.restoreGState()
                }
            case .none: break
            }
            var right = bounds.width - 10
            for k in it.keys.reversed() {
                for cap in k.split(separator: " ").reversed() {
                    let a = NSAttributedString(string: String(cap), attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Theme.textMuted])
                    let s = a.size()
                    let r = NSRect(x: right - s.width - 10, y: (bounds.height - 18) / 2, width: s.width + 10, height: 18)
                    Theme.codeBg.setFill()
                    NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                    a.draw(at: NSPoint(x: r.minX + 5, y: r.midY - s.height / 2))
                    right = r.minX - 2
                }
                right -= 4
            }
            if it.badge > 0 {
                let a = NSAttributedString(string: "\(it.badge)", attributes: [.font: Theme.Font.badge, .foregroundColor: NSColor.white])
                let s = a.size()
                let r = NSRect(x: right - max(18, s.width + 12), y: (bounds.height - 18) / 2, width: max(18, s.width + 12), height: 18)
                Theme.unreadRed.setFill()
                NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
                a.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
                right = r.minX - 6
            }
            let title = NSAttributedString(string: it.title, attributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: it.bold ? .semibold : .regular), .foregroundColor: Theme.textStrong])
            let ts = title.size()
            let tw = min(ts.width, right - 36 - 8)
            title.draw(with: NSRect(x: 36, y: (bounds.height - ts.height) / 2, width: tw, height: ts.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if !it.detail.isEmpty, 36 + tw + 8 < right - 20 {
                let d = NSAttributedString(string: it.detail, attributes: [.font: Theme.Font.small, .foregroundColor: Theme.textMuted])
                let ds = d.size()
                d.draw(with: NSRect(x: 36 + tw + 8, y: (bounds.height - ds.height) / 2, width: right - (36 + tw + 8) - 8, height: ds.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }
}

/// A tiny view that only draws a closure (static glyphs).
final class GlyphView: NSView {
    private let paint: (NSRect) -> Void
    init(_ paint: @escaping (NSRect) -> Void) { self.paint = paint; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { paint(bounds) }
}
