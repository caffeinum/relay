import AppKit
import ChatCore

/// A field over a list: ⌘K and / are both this. Typing refilters, ↑/↓ (or
/// ⌃n/⌃p) move, ↩ picks, esc closes.
class PickerOverlay: Overlay, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Item { let title: String; let detail: String; let run: () -> Void }

    let field = NSTextField()
    private var table: NSTableView!
    var items: [Item] = [] { didSet { table.reloadData(); if !items.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) } } }
    let note = NSTextField(labelWithString: "")

    init(placeholder: String, width: CGFloat = 600) {
        super.init(width: width, top: 90)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self
        note.font = .systemFont(ofSize: 11)
        note.textColor = Palette.secondary
        let scroll: NSScrollView
        (scroll, table) = makeTable(self, rowHeight: 40)
        table.target = self
        table.action = #selector(clicked)
        for v in [field, note, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(v) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            scroll.heightAnchor.constraint(equalToConstant: 360),
            note.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            note.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() { window?.makeFirstResponder(field) }

    func queryChanged(_ q: String) {}

    func controlTextDidChange(_ obj: Notification) { queryChanged(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): pick(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): onClose?()
        default: return false
        }
        return true
    }

    override func handle(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.control) else { return false }
        switch e.charactersIgnoringModifiers {
        case "n": move(1); return true
        case "p": move(-1); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !items.isEmpty else { return }
        let i = max(0, min(items.count - 1, table.selectedRow + d))
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    private func pick(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let run = items[i].run
        onClose?()
        run()
    }

    @objc private func clicked() { pick(table.clickedRow) }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let t = NSTextField(labelWithString: items[row].title)
        t.font = .systemFont(ofSize: 13.5, weight: .medium)
        t.lineBreakMode = .byTruncatingTail
        let d = NSTextField(labelWithString: items[row].detail)
        d.font = .systemFont(ofSize: 11.5)
        d.textColor = Palette.secondary
        d.lineBreakMode = .byTruncatingTail
        for v in [t, d] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([
            t.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            t.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
            d.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 1),
            d.leadingAnchor.constraint(equalTo: t.leadingAnchor),
            d.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
        ])
        return cell
    }
}

/// ⌘K: jump to any conversation, or run a command.
final class CommandOverlay: PickerOverlay {
    private let all: [Item]

    init(_ all: [Item]) {
        self.all = all
        super.init(placeholder: "Jump to a channel or run a command")
        note.stringValue = "↩ go   esc close"
        queryChanged("")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func queryChanged(_ q: String) {
        let words = q.lowercased().split(separator: " ")
        items = all.filter { item in
            let hay = (item.title + " " + item.detail).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

/// /: the cache answers as you type; Slack's search.messages fills in
/// older messages a moment later.
final class SearchOverlay: PickerOverlay {
    private let store: Store
    private let sync: Sync?
    var onHit: ((Hit) -> Void)?
    private var generation = 0
    private var remoteWork: DispatchWorkItem?

    init(store: Store, sync: Sync?) {
        self.store = store
        self.sync = sync
        super.init(placeholder: "Search messages")
        note.stringValue = "local results first, then Slack's"
    }

    required init?(coder: NSCoder) { fatalError() }

    private func items(_ hits: [Hit]) -> [Item] {
        hits.map { h in
            let when = DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(h.ts) ?? 0), dateStyle: .short, timeStyle: .short)
            return Item(title: Mrkdwn.plain(h.text, names: store.name(of:)).replacingOccurrences(of: "\n", with: " "),
                        detail: "\(h.channelName) · \(h.author) · \(when)\(h.remote ? " · slack" : "")",
                        run: { [weak self] in self?.onHit?(h) })
        }
    }

    override func queryChanged(_ q: String) {
        generation += 1
        let gen = generation
        let local: [Hit]
        do { local = try store.search(q) } catch {
            items = []
            note.stringValue = "Local search failed: \(error)"
            return
        }
        items = items(local)
        note.stringValue = q.isEmpty ? "local results first, then Slack's" : "\(local.count) in the cache"
        remoteWork?.cancel()
        guard let sync, q.count >= 2 else { return }
        let w = DispatchWorkItem { [weak self] in
            Task {
                do {
                    let remote = try await sync.remoteSearch(q)
                    await MainActor.run {
                        guard let self, self.generation == gen else { return }
                        let seen = Set(local.map { "\($0.channel)/\($0.ts)" })
                        let extra = remote.filter { !seen.contains("\($0.channel)/\($0.ts)") }
                        self.items = self.items(local + extra)
                        self.note.stringValue = "\(local.count) in the cache, \(extra.count) more from Slack"
                    }
                } catch {
                    await MainActor.run {
                        guard let self, self.generation == gen else { return }
                        self.note.stringValue = "\(local.count) in the cache. Slack search failed: \(error)"
                    }
                }
            }
        }
        remoteWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }
}
