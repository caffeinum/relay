import AppKit
import ChatCore

/// Channels and DMs: Unread first, then the local sections from config,
/// then everything else. Each conversation shows once.
final class Sidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 230

    enum Row { case header(String); case conv(Conversation) }
    private(set) var rows: [Row] = []
    private var table: NSTableView!
    private let title = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    var onSelect: ((Conversation) -> Void)?
    private(set) var current: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.sidebar.cgColor
        let (scroll, t) = makeTable(self, rowHeight: 26)
        table = t
        table.target = self
        table.action = #selector(clicked)
        title.font = .systemFont(ofSize: 14, weight: .bold)
        status.font = .systemFont(ofSize: 11)
        status.textColor = Palette.secondary
        status.lineBreakMode = .byTruncatingTail
        for v in [title, status, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var workspace: String { get { title.stringValue } set { title.stringValue = newValue } }

    var conversations: [Conversation] { rows.compactMap { if case .conv(let c) = $0 { return c }; return nil } }

    func show(_ all: [Conversation], sections: [Config.Section], current: String?) {
        self.current = current
        var used = Set<String>()
        var out: [Row] = []
        func add(_ title: String, _ cs: [Conversation]) {
            let cs = cs.filter { !used.contains($0.id) }
            guard !cs.isEmpty else { return }
            out.append(.header(title))
            for c in cs { out.append(.conv(c)); used.insert(c.id) }
        }
        let byRecent = all.sorted { $0.latest > $1.latest }
        add("Unread", byRecent.filter { $0.unread > 0 })
        for s in sections {
            let want = Set(s.channels.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 })
            add(s.name, all.filter { want.contains($0.name) || want.contains($0.id) }.sorted { $0.name < $1.name })
        }
        add("Channels", all.filter { !$0.isDM }.sorted { $0.name < $1.name })
        add("Direct messages", byRecent.filter(\.isDM))
        rows = out
        table.reloadData()
        if let current, let i = rows.firstIndex(where: { if case .conv(let c) = $0 { return c.id == current }; return false }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(i)
        }
    }

    /// The conversation `d` rows away from the current one, skipping headers.
    func neighbour(_ d: Int) -> Conversation? {
        let cs = conversations
        guard let i = cs.firstIndex(where: { $0.id == current }) else { return cs.first }
        let j = i + d
        return cs.indices.contains(j) ? cs[j] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return row == 0 ? 24 : 34 }
        return 26
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        var c = [label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                 label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5)]
        switch rows[row] {
        case .header(let t):
            label.stringValue = t.uppercased()
            label.font = .systemFont(ofSize: 10.5, weight: .semibold)
            label.textColor = Palette.secondary
            c.append(label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12))
        case .conv(let conv):
            label.stringValue = conv.label
            label.font = .systemFont(ofSize: 13, weight: conv.unread > 0 ? .semibold : .regular)
            label.textColor = conv.unread > 0 ? .labelColor : Palette.secondary
            let badge = NSTextField(labelWithString: conv.unread > 0 ? (conv.mentions > 0 ? "@\(conv.mentions)" : "\(conv.unread)") : "")
            badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            badge.textColor = conv.mentions > 0 ? Palette.mention : Palette.secondary
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(badge)
            c += [badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
                  badge.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
                  label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6)]
        }
        NSLayoutConstraint.activate(c)
        return cell
    }

    @objc private func clicked() {
        let r = table.clickedRow
        guard r >= 0, case .conv(let c) = rows[r] else { return }
        onSelect?(c)
    }
}
