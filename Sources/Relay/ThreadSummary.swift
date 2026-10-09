import AppKit
import RelayCore

/// "3 replies · Last reply 2 hours ago" under a channel message (§5.7),
/// drawn in one view; hover turns it into a card with "View thread ›".
final class ThreadSummaryView: NSView {
    struct Model: Equatable {
        var count: Int
        var latest: Date?
        var repliers: [(id: String, name: String, url: String?)]
        var draft: Bool
        var unread: Bool

        static func == (a: Model, b: Model) -> Bool {
            a.count == b.count && a.latest == b.latest && a.draft == b.draft && a.unread == b.unread && a.repliers.map(\.id) == b.repliers.map(\.id)
        }
    }

    static let height: CGFloat = 24
    var model = Model(count: 0, latest: nil, repliers: [], draft: false, unread: false) { didSet { if model != oldValue { needsDisplay = true } } }
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var onOpen: (() -> Void)?
    private static let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f }()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        if hovered {
            let path = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            Theme.bgRaised.setFill(); path.fill()
            Theme.border.setStroke(); path.lineWidth = 1; path.stroke()
        }
        var x: CGFloat = 2
        for r in model.repliers.prefix(3) {
            let img = Avatars.shared.layerContents(for: r.id, name: r.name, url: r.url, size: 20)
            let rect = NSRect(x: x, y: 2, width: 20, height: 20)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            NSImage(cgImage: img, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            x += 24
        }
        if !model.repliers.isEmpty { x += 4 }
        if model.draft {
            Symbols.draw("pencil", 11, color: Theme.textMuted, in: NSRect(x: x, y: 4, width: 14, height: 16))
            x += 16
            x = drawText("Draft", Theme.Font.small, Theme.textMuted, at: x) + 8
        }
        if model.unread {
            Theme.unreadRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 9, width: 6, height: 6)).fill()
            x += 10
        }
        let n = model.count == 1 ? "1 reply" : "\(model.count) replies"
        x = drawText(n, model.unread ? NSFont.systemFont(ofSize: 12, weight: .bold) : Theme.Font.smallSemibold, Theme.link, at: x) + 8
        if hovered {
            _ = drawText("View thread", Theme.Font.small, Theme.textMuted, at: x)
            Symbols.draw("chevron.right", 10, .semibold, color: Theme.textMuted, in: NSRect(x: b.maxX - 22, y: 4, width: 16, height: 16))
        } else if let latest = model.latest {
            _ = drawText("Last reply " + Self.relative.localizedString(for: latest, relativeTo: Date()), Theme.Font.small, Theme.textMuted, at: x)
        }
    }

    private func drawText(_ s: String, _ f: NSFont, _ c: NSColor, at x: CGFloat) -> CGFloat {
        let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
        let size = a.size()
        a.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
        return x + size.width
    }

    override func mouseDown(with event: NSEvent) { onOpen?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
