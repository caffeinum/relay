import AppKit
import RelayCore

enum Palette {
    static let background = NSColor.textBackgroundColor
    static let sidebar = NSColor.windowBackgroundColor
    static let accent = NSColor.controlAccentColor
    static let secondary = NSColor.secondaryLabelColor
    static let mention = NSColor.systemOrange
    static let selection = NSColor.controlAccentColor.withAlphaComponent(0.14)
}

final class KeyWindow: NSWindow {
    var router: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let chord = !event.modifierFlags.intersection([.command, .control]).isEmpty
        if chord, let router, router(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        let chord = !event.modifierFlags.intersection([.command, .control]).isEmpty
        if event.type == .keyDown, !chord, let router, router(event) { return }
        super.sendEvent(event)
    }

    var isEditingText: Bool {
        guard let r = firstResponder else { return false }
        if let tv = r as? NSTextView { return tv.isEditable }
        return r is NSTextField
    }
}

final class Toast: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hide: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        label.textColor = .textBackgroundColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: String, error: Bool = false) {
        label.stringValue = s
        layer?.backgroundColor = (error ? NSColor.systemRed : NSColor.labelColor).withAlphaComponent(0.88).cgColor
        isHidden = false
        alphaValue = 1
        hide?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self?.animator().alphaValue = 0 }) { self?.isHidden = true }
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 6 : 2.2), execute: w)
    }
}

/// A card drawn over the window (⌘K, search), not a window of its own.
class Overlay: NSView {
    let card = NSView()
    var onClose: (() -> Void)?

    init(width: CGFloat, top: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        card.wantsLayer = true
        card.layer?.backgroundColor = Palette.background.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: width),
            card.topAnchor.constraint(equalTo: topAnchor, constant: top),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    func show(in host: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor), bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor), trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }

    /// Up/down/return/esc from the field; everything else types.
    func handle(_ e: NSEvent) -> Bool { false }
}

/// A plain, borderless, single-column table in a scroll view.
func makeTable(_ owner: NSTableViewDataSource & NSTableViewDelegate, rowHeight: CGFloat = 24) -> (NSScrollView, NSTableView) {
    let table = NSTableView()
    let col = NSTableColumn(identifier: .init("c"))
    col.resizingMask = .autoresizingMask
    table.addTableColumn(col)
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.headerView = nil
    table.rowHeight = rowHeight
    table.intercellSpacing = .zero
    table.style = .plain
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .regular
    table.dataSource = owner
    table.delegate = owner
    table.refusesFirstResponder = true
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    return (scroll, table)
}

func pin(_ v: NSView, in host: NSView, insets: NSEdgeInsets = .init()) {
    v.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(v)
    NSLayoutConstraint.activate([
        v.topAnchor.constraint(equalTo: host.topAnchor, constant: insets.top),
        v.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -insets.bottom),
        v.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: insets.left),
        v.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -insets.right),
    ])
}
