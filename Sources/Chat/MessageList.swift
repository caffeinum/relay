import AppKit
import ChatCore

/// Messages drawn as attributed text, heights measured up front so a
/// channel's worth of rows lays out in one pass. Used for the channel and
/// for the thread pane.
final class MessageList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var messages: [Message] = []
    private var texts: [NSAttributedString] = []
    private var heights: [CGFloat] = []
    private var measuredWidth: CGFloat = 0
    private(set) var table: NSTableView!
    private var scroll: NSScrollView!
    var names: (String) -> String = { $0 }
    var inThread = false
    var onNearTop: (() -> Void)?
    var onOpen: ((Int) -> Void)?
    var focused = true { didSet { table.needsDisplay = true; updateSelectionStyle() } }
    let empty = NSTextField(labelWithString: "")
    static let pad = NSEdgeInsets(top: 6, left: 18, bottom: 6, right: 18)

    override init(frame: NSRect) {
        super.init(frame: frame)
        (scroll, table) = makeTable(self)
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        pin(scroll, in: self)
        empty.textColor = Palette.secondary
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor)])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    var selected: Int? { table.selectedRow >= 0 ? table.selectedRow : nil }
    var selectedMessage: Message? { selected.map { messages[$0] } }

    /// New rows. Keeps the cursor on the same message when it's still there,
    /// and otherwise lands on `cursor` (default: the last row).
    func show(_ ms: [Message], keep: Bool = true, cursor: Int? = nil) {
        let prevTS = keep ? selectedMessage?.ts : nil
        let atBottom = isAtBottom
        let firstVisibleTS = visibleTop
        messages = ms
        texts = ms.map { render($0) }
        measuredWidth = 0
        measure()
        table.reloadData()
        empty.isHidden = !ms.isEmpty
        guard !ms.isEmpty else { return }
        if let prevTS, let i = ms.firstIndex(where: { $0.ts == prevTS }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            if atBottom { scrollToBottom() } else if let firstVisibleTS, let j = ms.firstIndex(where: { $0.ts == firstVisibleTS }) {
                table.scroll(NSPoint(x: 0, y: table.rect(ofRow: j).minY))
            }
        } else {
            select(cursor ?? ms.count - 1)
            if cursor == nil { scrollToBottom() }
        }
    }

    private var isAtBottom: Bool {
        let visible = scroll.contentView.bounds
        return visible.maxY >= table.bounds.height - 4
    }

    private var visibleTop: String? {
        let r = table.rows(in: scroll.contentView.bounds)
        return r.length > 0 && r.location < messages.count ? messages[r.location].ts : nil
    }

    func scrollToBottom() {
        guard !messages.isEmpty else { return }
        table.scrollRowToVisible(messages.count - 1)
    }

    func select(_ i: Int) {
        guard !messages.isEmpty else { return }
        let i = max(0, min(messages.count - 1, i))
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    func step(_ d: Int) {
        guard let s = selected else { select(d > 0 ? 0 : messages.count - 1); return }
        select(s + d)
        if s + d < 0 { onNearTop?() }
    }

    private func updateSelectionStyle() {
        table.enumerateAvailableRowViews { row, _ in (row as? MessageRow)?.dim = !self.focused }
    }

    // MARK: rendering

    private static let timeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM, h:mm a"; return f }()

    private func render(_ m: Message) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13.5)
        s.append(NSAttributedString(string: m.author, attributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        let fmt = Calendar.current.isDateInToday(m.date) ? Self.timeFormat : Self.dayFormat
        s.append(NSAttributedString(string: "  " + fmt.string(from: m.date), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.secondary]))
        s.append(NSAttributedString(string: "\n"))
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor]
        for run in Mrkdwn.runs(m.text, names: names) {
            switch run {
            case .text(let t): s.append(NSAttributedString(string: Emoji.replace(t), attributes: plain))
            case .mention(let t), .channel(let t):
                s.append(NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 13.5, weight: .medium), .foregroundColor: Palette.mention]))
            case .link(let label, let url):
                var a = plain
                a[.foregroundColor] = Palette.accent
                if let u = URL(string: url) { a[.link] = u }
                s.append(NSAttributedString(string: label, attributes: a))
            }
        }
        if m.edited { s.append(NSAttributedString(string: " (edited)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.secondary])) }
        if !m.reactions.isEmpty {
            let r = m.reactions.map { "\(Emoji.glyph($0.name)) \($0.count)" }.joined(separator: "   ")
            s.append(NSAttributedString(string: "\n" + r, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.secondary]))
        }
        if !inThread && m.replyCount > 0 {
            let n = m.replyCount == 1 ? "1 reply" : "\(m.replyCount) replies"
            s.append(NSAttributedString(string: "\n" + n + "  ↩", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: Palette.accent]))
        }
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
    }

    private func measure() {
        let w = max(100, bounds.width - Self.pad.left - Self.pad.right)
        guard w != measuredWidth else { return }
        measuredWidth = w
        heights = texts.map { ceil($0.boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + Self.pad.top + Self.pad.bottom + 4 }
    }

    override func layout() {
        super.layout()
        let before = measuredWidth
        measure()
        if before != measuredWidth, !messages.isEmpty {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<messages.count))
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { row < heights.count ? heights[row] : 40 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = MessageRow()
        r.dim = !focused
        return r
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("m")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? MessageCell) ?? MessageCell(id)
        cell.text.attributedStringValue = texts[row]
        return cell
    }

    @objc private func clicked() { if table.clickedRow >= 0 { select(table.clickedRow) } }
    @objc private func doubleClicked() { if table.clickedRow >= 0 { onOpen?(table.clickedRow) } }

    @objc private func scrolled() {
        if scroll.contentView.bounds.minY < 40, !messages.isEmpty { onNearTop?() }
    }
}

final class MessageCell: NSTableCellView {
    let text = NSTextField(wrappingLabelWithString: "")

    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        text.isSelectable = true
        text.allowsEditingTextAttributes = true
        text.drawsBackground = false
        let p = MessageList.pad
        pin(text, in: self, insets: NSEdgeInsets(top: p.top, left: p.left, bottom: p.bottom, right: p.right))
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The cursor: a bar on the left and a tint, dimmer when the other pane has focus.
final class MessageRow: NSTableRowView {
    var dim = false { didSet { needsDisplay = true } }

    override func drawSelection(in dirtyRect: NSRect) {
        Palette.accent.withAlphaComponent(dim ? 0.05 : 0.10).setFill()
        bounds.fill()
        (dim ? Palette.secondary : Palette.accent).setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
    }

    override var isEmphasized: Bool { get { true } set {} }
}
