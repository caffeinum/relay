import AppKit
import RelayCore

/// Floating views over the message list (§5.9, §5.10): one instance each,
/// faded, never laid out per row.
class FloatingPill: NSView {
    var onClick: ((NSPoint) -> Void)?
    private(set) var shown = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        if on { isHidden = false }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0 : 0.15
            animator().alphaValue = on ? 1 : 0
        }) { [weak self] in if self?.shown == false { self?.isHidden = true } }
    }

    override func mouseDown(with event: NSEvent) { onClick?(convert(event.locationInWindow, from: nil)) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func hitTest(_ point: NSPoint) -> NSView? { shown ? super.hitTest(point) : nil }

    func shadow(_ on: Bool) {
        guard let l = layer else { return }
        if on { Theme.floatShadow(l, radius: bounds.height / 2, dark: Theme.isDark(self)) } else { l.shadowOpacity = 0 }
    }
}

/// The current day, pinned 8 below the top while its separator is scrolled away.
final class StickyDay: FloatingPill {
    var label = "" { didSet { if label != oldValue { resize() } } }

    private func resize() {
        var s = DayPill.size(label)
        s.width += 14
        let cx = frame.midX
        frame = NSRect(x: (cx - s.width / 2).rounded(), y: frame.minY, width: s.width, height: s.height)
        shadow(true)
        needsDisplay = true
    }

    func place(centerX: CGFloat, top: CGFloat) {
        let s = frame.size
        setFrameOrigin(NSPoint(x: (centerX - s.width / 2).rounded(), y: top))
    }

    override func draw(_ dirtyRect: NSRect) { DayPill.draw(label, centeredIn: bounds, chevron: true) }
}

/// "↑ 12 new messages | Mark as read" (red) or "↑ 2 mentions" (purple), and
/// the jump-to-bottom circle that grows into "↓ 3 new".
final class JumpPill: FloatingPill {
    enum Kind: Equatable { case unread(Int), mentions(Int), bottom(newCount: Int) }
    var kind: Kind = .bottom(newCount: 0) { didSet { if kind != oldValue { resize() } } }
    private(set) var markRect: NSRect = .zero
    private var isMentions: Bool { if case .mentions = kind { return true }; return false }

    private var title: String {
        switch kind {
        case .unread(let n): return "\(n) new message\(n == 1 ? "" : "s")"
        case .mentions(let n): return "\(n) mention\(n == 1 ? "" : "s")"
        case .bottom(let n): return n > 0 ? "\(n) new" : ""
        }
    }

    private static func attr(_ s: String, _ c: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: c])
    }

    var preferredSize: NSSize {
        switch kind {
        case .bottom(let n) where n == 0: return NSSize(width: 32, height: 32)
        case .bottom: return NSSize(width: (Self.attr(title, .white).size().width + 44).rounded(.up), height: 32)
        case .unread: return NSSize(width: (Self.attr(title, .white).size().width + Self.attr("Mark as read", .white).size().width + 74).rounded(.up), height: 28)
        case .mentions: return NSSize(width: (Self.attr(title, .white).size().width + 44).rounded(.up), height: 28)
        }
    }

    private func resize() {
        setFrameSize(preferredSize)
        shadow(true)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let path = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: b.height / 2, yRadius: b.height / 2)
        switch kind {
        case .bottom(let n):
            Theme.bgRaised.setFill(); path.fill()
            Theme.border.setStroke(); path.lineWidth = 1; path.stroke()
            if n == 0 {
                Symbols.draw("arrow.down", 13, .semibold, color: Theme.text, in: b)
            } else {
                Symbols.draw("arrow.down", 11, .bold, color: Theme.link, in: NSRect(x: 12, y: 0, width: 14, height: b.height))
                let a = Self.attr(title, Theme.link)
                a.draw(at: NSPoint(x: 30, y: (b.height - a.size().height) / 2))
            }
        case .unread, .mentions:
            (isMentions ? Theme.accentPill : Theme.unreadRed).setFill()
            path.fill()
            Symbols.draw("arrow.up", 10, .bold, color: .white, in: NSRect(x: 12, y: 0, width: 12, height: b.height))
            let a = Self.attr(title, .white)
            let s = a.size()
            a.draw(at: NSPoint(x: 28, y: (b.height - s.height) / 2))
            if case .unread = kind {
                let sx = 28 + s.width + 10
                NSColor.white.withAlphaComponent(0.4).setFill()
                NSRect(x: sx, y: 7, width: 1, height: b.height - 14).fill()
                let m = Self.attr("Mark as read", .white)
                m.draw(at: NSPoint(x: sx + 10, y: (b.height - m.size().height) / 2))
                Symbols.draw("checkmark", 10, .bold, color: .white, in: NSRect(x: b.width - 22, y: 0, width: 12, height: b.height))
                markRect = NSRect(x: sx, y: 0, width: b.width - sx, height: b.height)
            } else {
                markRect = .zero
            }
        }
    }
}
