import AppKit
import RelayCore

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

/// D§9: toasts stack upward from the bottom of the message pane, three at
/// most. Errors stay 6 s and go to the log; the undo toast counts down
/// with a strokeEnd animation and offers Undo (z).
final class Toast: NSStackView {
    enum Kind { case info, success, error }

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .centerX
        spacing = 6
    }

    required init?(coder: NSCoder) { fatalError() }

    private(set) var last: String?

    func show(_ s: String, error: Bool = false) { show(s, kind: error ? .error : .info) }

    func show(_ s: String, kind: Kind, seconds: Double? = nil) {
        if kind == .error { log("toast: \(s)") }
        last = s
        add(ToastView(text: s, kind: kind, undo: nil, seconds: seconds ?? (kind == .error ? 6 : 2.2)))
    }

    /// "Message sent · Undo (z)" for the outbox's window.
    func undo(_ s: String, seconds: Double, onUndo: @escaping () -> Void) {
        last = s
        add(ToastView(text: s, kind: .info, undo: onUndo, seconds: seconds))
    }

    func dismissUndo() { arrangedSubviews.compactMap { $0 as? ToastView }.filter(\.isUndo).forEach { $0.dismiss() } }

    private func add(_ v: ToastView) {
        while arrangedSubviews.count >= 3 { arrangedSubviews.first?.removeFromSuperview() }
        addArrangedSubview(v)
        v.start()
    }
}

final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let kind: Toast.Kind
    private let onUndo: (() -> Void)?
    private let seconds: Double
    private let progress = CAShapeLayer()
    var isUndo: Bool { onUndo != nil }

    init(text: String, kind: Toast.Kind, undo: (() -> Void)?, seconds: Double) {
        self.kind = kind
        self.onUndo = undo
        self.seconds = seconds
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = false
        let pre = kind == .success ? "✓  " : kind == .error ? "⚠︎  " : ""
        let a = NSMutableAttributedString(string: pre + text, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: kind == .error ? NSColor.white : NSColor.textBackgroundColor])
        if kind == .success { a.addAttribute(.foregroundColor, value: Theme.success, range: NSRange(location: 0, length: 1)) }
        if undo != nil {
            a.append(NSAttributedString(string: "  ·  ", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.6)]))
            a.append(NSAttributedString(string: "Undo (z)", attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.link]))
        }
        label.attributedStringValue = a
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        if undo != nil {
            progress.strokeColor = Theme.link.cgColor
            progress.lineWidth = 2
            progress.fillColor = nil
            layer?.addSublayer(progress)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = kind == .error ? Theme.unreadRed.cgColor : NSColor.labelColor.withAlphaComponent(0.92).cgColor
    }

    override func layout() {
        super.layout()
        guard let l = layer else { return }
        Theme.floatShadow(l, radius: 8, dark: Theme.isDark(self))
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 8, y: 1))
        p.addLine(to: CGPoint(x: bounds.width - 8, y: 1))
        progress.path = p
        progress.frame = bounds
    }

    func start() {
        if isUndo {
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = 1
            a.toValue = 0
            a.duration = seconds
            progress.strokeEnd = 0
            progress.add(a, forKey: "countdown")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.dismiss() }
    }

    func dismiss() {
        guard superview != nil else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 }) { [weak self] in self?.removeFromSuperview() }
    }

    override func mouseDown(with event: NSEvent) {
        if let onUndo { onUndo(); dismiss() }
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
        card.layer?.backgroundColor = Theme.bg.cgColor
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
