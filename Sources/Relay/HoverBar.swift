import AppKit
import RelayCore

/// The one action bar (§5.4), moved between rows by MessageList. It draws
/// its buttons itself and becomes the inline "Delete message?" strip.
final class HoverBar: NSView, NSViewToolTipOwner {
    enum Action: Equatable { case react, quick(String), reply, share, save, edit, delete, more }

    private struct Button { var action: Action; var rect: NSRect; var tip: String }

    static let height: CGFloat = 34
    private(set) var confirming = false
    private var buttons: [Button] = []
    private var dividerX: CGFloat?
    private var hoveredIndex: Int? { didSet { if hoveredIndex != oldValue { needsDisplay = true } } }
    private var confirmButtons: (cancel: NSRect, delete: NSRect) = (.zero, .zero)
    private var mine = false
    private var quick: [String] = []
    var onAction: ((Action) -> Void)?
    var onConfirm: ((Bool) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = Theme.Radius.card
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Lays out the buttons for a message and returns the bar's width.
    @discardableResult
    func configure(mine: Bool, quick: [String]) -> CGFloat {
        if self.mine == mine, self.quick == quick, !buttons.isEmpty, !confirming { return frame.width }
        self.mine = mine
        self.quick = quick
        confirming = false
        var acts: [(Action, String)] = [(.react, "Add reaction  +")]
        for (i, q) in quick.prefix(3).enumerated() { acts.append((.quick(q), ":\(q):  \(i + 1)")) }
        let split = acts.count
        acts += [(.reply, "Reply in thread  r"), (.share, "Copy link  c"), (.save, "Save for later  s")]
        if mine { acts += [(.edit, "Edit message  e"), (.delete, "Delete message  d")] }
        acts.append((.more, "More actions  ."))
        var x: CGFloat = 2
        buttons = []
        dividerX = nil
        for (i, a) in acts.enumerated() {
            if i == split { dividerX = x + 4; x += 9 }
            buttons.append(Button(action: a.0, rect: NSRect(x: x, y: 2, width: 30, height: 30), tip: a.1))
            x += 30
        }
        rebuildTips()
        needsDisplay = true
        return x + 2
    }

    func beginConfirm() -> CGFloat {
        confirming = true
        hoveredIndex = nil
        removeAllToolTips()
        let label = NSAttributedString(string: "Delete message?", attributes: [.font: Theme.Font.small, .foregroundColor: Theme.text]).size().width
        let x = 12 + label.rounded(.up) + 12
        confirmButtons = (NSRect(x: x, y: 5, width: 60, height: 24), NSRect(x: x + 66, y: 5, width: 60, height: 24))
        needsDisplay = true
        return x + 66 + 60 + 6
    }

    func endConfirm() {
        confirming = false
        buttons = []
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if let l = layer { Theme.floatShadow(l, radius: Theme.Radius.card, dark: Theme.isDark(self)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.bgRaised.setFill(); path.fill()
        Theme.borderStrong.withAlphaComponent(0.6).setStroke(); path.lineWidth = 1; path.stroke()
        if confirming { drawConfirm(); return }
        if let d = dividerX {
            Theme.border.setFill()
            NSRect(x: d, y: 9, width: 1, height: 16).fill()
        }
        for (i, b) in buttons.enumerated() {
            let hovered = hoveredIndex == i
            if hovered {
                (b.action == .delete ? Theme.unreadRed.withAlphaComponent(0.15) : Theme.bgHover).setFill()
                NSBezierPath(roundedRect: b.rect, xRadius: 6, yRadius: 6).fill()
            }
            let color = hovered ? (b.action == .delete ? Theme.unreadRed : Theme.textStrong) : Theme.textMuted
            switch b.action {
            case .react:
                Symbols.draw("face.smiling", 14, color: color, in: b.rect.offsetBy(dx: -1, dy: 0))
                Symbols.draw("plus", 7, .bold, color: color, in: NSRect(x: b.rect.maxX - 12, y: b.rect.minY + 5, width: 8, height: 8))
            case .quick(let name):
                let g = NSAttributedString(string: EmojiData.glyph(name) ?? ":\(name):", attributes: [.font: NSFont.systemFont(ofSize: 16)])
                let s = g.size()
                g.draw(at: NSPoint(x: b.rect.midX - s.width / 2, y: b.rect.midY - s.height / 2))
            case .reply: Symbols.draw("bubble.left", 14, color: color, in: b.rect)
            case .share: Symbols.draw("arrowshape.turn.up.right", 14, color: color, in: b.rect)
            case .save: Symbols.draw("bookmark", 14, color: color, in: b.rect)
            case .edit: Symbols.draw("pencil", 14, color: color, in: b.rect)
            case .delete: Symbols.draw("trash", 14, color: color, in: b.rect)
            case .more: Symbols.draw("ellipsis", 14, .bold, color: color, in: b.rect)
            }
        }
    }

    private func drawConfirm() {
        let label = NSAttributedString(string: "Delete message?", attributes: [.font: Theme.Font.small, .foregroundColor: Theme.text])
        let s = label.size()
        label.draw(at: NSPoint(x: 12, y: (bounds.height - s.height) / 2))
        let c = confirmButtons
        let cancel = NSBezierPath(roundedRect: c.cancel.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (hoveredIndex == 0 ? Theme.bgHover : Theme.bgRaised).setFill(); cancel.fill()
        Theme.border.setStroke(); cancel.stroke()
        Theme.unreadRed.setFill()
        NSBezierPath(roundedRect: c.delete, xRadius: 6, yRadius: 6).fill()
        for (r, t, color) in [(c.cancel, "Cancel", Theme.text), (c.delete, "Delete", NSColor.white)] {
            let a = NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color])
            let ts = a.size()
            a.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
        }
    }

    // MARK: mouse

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    func hover(at p: NSPoint?) {
        guard let p else { hoveredIndex = nil; return }
        if confirming { hoveredIndex = confirmButtons.cancel.contains(p) ? 0 : nil; return }
        hoveredIndex = buttons.firstIndex { $0.rect.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if confirming {
            if confirmButtons.delete.contains(p) { onConfirm?(true) } else if confirmButtons.cancel.contains(p) { onConfirm?(false) }
            return
        }
        if let b = buttons.first(where: { $0.rect.contains(p) }) { onAction?(b.action) }
    }

    private func rebuildTips() {
        removeAllToolTips()
        for b in buttons { addToolTip(b.rect, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        buttons.first { $0.rect.contains(point) }?.tip ?? ""
    }

    /// For the script and tests: the actions shown, left to right.
    var actions: [Action] { buttons.map(\.action) }
}
