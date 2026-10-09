import AppKit
import RelayCore

/// Hover is a plain fill; the keyboard cursor is a bar plus a tint drawn
/// over it (§5.3). Mentions of me and the inline editor tint the whole row.
final class MessageRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("messageRow")
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var dim = false { didSet { if dim != oldValue { needsDisplay = true } } }
    var mentionsMe = false { didSet { if mentionsMe != oldValue { needsDisplay = true } } }
    var editing = false { didSet { if editing != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEmphasized: Bool { get { true } set {} }

    override func drawBackground(in dirtyRect: NSRect) {
        if editing {
            Theme.editingRow.setFill(); bounds.fill()
            return
        }
        if mentionsMe {
            Theme.mentionMeRow.setFill(); bounds.fill()
        }
        if hovered {
            Theme.bgHover.setFill(); bounds.fill()
        }
        if mentionsMe, !isSelected {
            Theme.mentionMeBar.setFill()
            NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        (dim ? Theme.cursorTintDim : Theme.cursorTint).setFill()
        bounds.fill()
        (dim ? Theme.textFaint : Theme.cursor).setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
    }
}

/// The text of one body, drawn straight from a TextKit stack: no
/// NSTextView (its first init alone costs ~25 ms). Links are hit-tested
/// from the same layout.
final class BodyView: NSView {
    let storage = NSTextStorage()
    let manager = BodyLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
    var onMouseDown: (() -> Void)?
    var onLink: ((URL, NSRect) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: NSAttributedString, width: CGFloat) {
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(text)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyphs = manager.glyphRange(forBoundingRect: dirtyRect, in: container)
        manager.drawBackground(forGlyphRange: glyphs, at: .zero)
        manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    private func link(at p: NSPoint) -> (URL, NSRect)? {
        guard storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let g = manager.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
        guard rect.insetBy(dx: -2, dy: -2).contains(p) else { return nil }
        let c = manager.characterIndexForGlyph(at: g)
        guard c < storage.length, let url = storage.attribute(.relayLink, at: c, effectiveRange: nil) as? URL else { return nil }
        return (url, rect)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (url, rect) = link(at: p) { onLink?(url, rect); return }
        onMouseDown?()
    }

    override func resetCursorRects() {
        guard storage.length > 0 else { return }
        storage.enumerateAttribute(.relayLink, in: NSRange(location: 0, length: storage.length)) { v, range, _ in
            guard v != nil else { return }
            let gr = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: gr, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { r, _ in
                self.addCursorRect(r, cursor: .pointingHand)
            }
        }
    }
}

struct RowGeometry {
    static let gutter: CGFloat = 20, avatar: CGFloat = 36, content: CGFloat = 64
    var width: CGFloat
    var height: CGFloat
    var top: CGFloat
    var bodyTop: CGFloat
    var bodyHeight: CGFloat
    var pills: [PillLayout]
    var add: NSRect
    var reactionsTop: CGFloat
    var reactionsHeight: CGFloat
    var threadTop: CGFloat?
    var footTop: CGFloat?

    var contentWidth: CGFloat { max(60, width - Self.content - Self.gutter) }
}

final class MessageCellView: NSView {
    static let id = NSUserInterfaceItemIdentifier("message")
    let body = BodyView()
    let reactions = ReactionStrip()
    let thread = ThreadSummaryView()
    private let avatar = CALayer()
    private var header: NSAttributedString?
    private var nameWidth: CGFloat = 0
    private var gutterTime: NSAttributedString?
    private var foot: NSAttributedString?
    private(set) var geo: RowGeometry?
    private var shown: NSAttributedString?
    var showGutterTime = false { didSet { if showGutterTime != oldValue, gutterTime != nil { setNeedsDisplay(NSRect(x: 0, y: 0, width: 60, height: 30)) } } }
    var onAvatar: ((NSRect) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        avatar.cornerRadius = Theme.Radius.avatar
        avatar.masksToBounds = true
        avatar.contentsGravity = .resizeAspectFill
        avatar.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(avatar)
        addSubview(body)
        addSubview(reactions)
        addSubview(thread)
    }

    required init?(coder: NSCoder) { fatalError() }

    struct Header {
        var author: String
        var bot: Bool
        var time: String
        var tooltip: String
    }

    func configure(body text: NSAttributedString, header h: Header?, gutter: String?, avatar img: CGImage?, bot: Bool,
                   geo g: RowGeometry, thread t: ThreadSummaryView.Model?, foot f: NSAttributedString?, alpha: CGFloat) {
        geo = g
        body.frame = NSRect(x: RowGeometry.content, y: g.bodyTop, width: g.contentWidth, height: g.bodyHeight)
        if shown !== text || body.container.size.width != g.contentWidth {
            shown = text
            body.set(text, width: g.contentWidth)
        }
        body.alphaValue = alpha
        if let h {
            let s = NSMutableAttributedString(string: h.author, attributes: [.font: Theme.Font.name, .foregroundColor: Theme.textStrong])
            nameWidth = s.size().width
            if h.bot {
                s.append(NSAttributedString(string: " ", attributes: [.font: Theme.Font.name]))
                s.append(NSAttributedString(string: "\u{2009}APP\u{2009}", attributes: [.font: Theme.Font.tag, .foregroundColor: Theme.textMuted,
                                                                                        .backgroundColor: Theme.codeBg, .baselineOffset: 1]))
            }
            s.append(NSAttributedString(string: "  " + h.time, attributes: [.font: Theme.Font.meta, .foregroundColor: Theme.textMuted, .baselineOffset: 0.5]))
            header = s
            toolTip = nil
            avatar.isHidden = false
            avatar.frame = NSRect(x: RowGeometry.gutter, y: g.top, width: RowGeometry.avatar, height: RowGeometry.avatar)
            avatar.cornerRadius = bot ? 8 : Theme.Radius.avatar
            avatar.contents = img
            avatar.contentsScale = window?.backingScaleFactor ?? 2
        } else {
            header = nil
            avatar.isHidden = true
            avatar.contents = nil
        }
        gutterTime = gutter.map { NSAttributedString(string: $0, attributes: [.font: Theme.Font.hoverTime, .foregroundColor: Theme.textFaint]) }
        reactions.isHidden = g.pills.isEmpty
        if !g.pills.isEmpty {
            reactions.frame = NSRect(x: RowGeometry.content, y: g.reactionsTop, width: g.contentWidth, height: g.reactionsHeight)
            reactions.pills = g.pills
            reactions.addRect = g.add
        }
        if let t, let top = g.threadTop {
            thread.isHidden = false
            thread.model = t
            thread.frame = NSRect(x: RowGeometry.content - 2, y: top, width: min(g.contentWidth + 2, 600), height: ThreadSummaryView.height)
        } else {
            thread.isHidden = true
        }
        foot = f
        needsDisplay = true
    }

    func setAvatar(_ img: CGImage) { avatar.contents = img }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = geo else { return }
        if let header {
            header.draw(at: NSPoint(x: RowGeometry.content, y: g.top - 1))
        }
        if showGutterTime, header == nil, let gutterTime {
            let s = gutterTime.size()
            gutterTime.draw(at: NSPoint(x: 56 - s.width, y: g.bodyTop + (Body.lineHeight - s.height) / 2 + 1))
        }
        if let foot, let top = g.footTop { foot.draw(at: NSPoint(x: RowGeometry.content, y: top)) }
    }

    /// The author's name and avatar, in this view's coordinates, for the profile popover.
    var authorRects: [NSRect] {
        guard let g = geo, header != nil else { return [] }
        return [avatar.frame, NSRect(x: RowGeometry.content, y: g.top, width: nameWidth, height: 20)]
    }
}

/// The date separator (§5.9): a full-width line with a centered pill.
final class DayCellView: NSView {
    static let id = NSUserInterfaceItemIdentifier("day")
    static let height: CGFloat = 40
    var label = "" { didSet { if label != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        NSRect(x: 0, y: (bounds.midY).rounded(.down), width: bounds.width, height: 1).fill()
        DayPill.draw(label, centeredIn: bounds)
    }
}

enum DayPill {
    static func size(_ label: String) -> NSSize {
        let w = NSAttributedString(string: label, attributes: [.font: Theme.Font.dayPill]).size().width
        return NSSize(width: (w + 28).rounded(.up), height: 26)
    }

    static func draw(_ label: String, centeredIn b: NSRect, chevron: Bool = false) {
        let a = NSAttributedString(string: label, attributes: [.font: Theme.Font.dayPill, .foregroundColor: Theme.textStrong])
        var s = size(label)
        if chevron { s.width += 14 }
        let r = NSRect(x: (b.midX - s.width / 2).rounded(), y: (b.midY - s.height / 2).rounded(), width: s.width, height: s.height)
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        Theme.bg.setFill(); path.fill()
        Theme.border.setStroke(); path.lineWidth = 1; path.stroke()
        let ts = a.size()
        a.draw(at: NSPoint(x: r.minX + 14, y: r.midY - ts.height / 2))
        if chevron { Glyphs.chevronDown(in: NSRect(x: r.maxX - 24, y: r.minY, width: 10, height: r.height), Theme.textMuted, flipped: NSGraphicsContext.current?.isFlipped ?? true) }
    }
}

/// "New" divider (§5.8): a red rule with the label cutting it at the right.
final class UnreadCellView: NSView {
    static let id = NSUserInterfaceItemIdentifier("unread")
    static let height: CGFloat = 24
    private static let label = NSAttributedString(string: "New", attributes: [.font: Theme.Font.dividerLabel, .foregroundColor: Theme.unreadRed])

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let y = (bounds.midY).rounded(.down)
        Theme.unreadRed.setFill()
        NSRect(x: 20, y: y, width: bounds.width - 40, height: 1).fill()
        let s = Self.label.size()
        let r = NSRect(x: bounds.width - 20 - s.width - 12, y: y - s.height / 2, width: s.width + 12, height: s.height)
        Theme.bg.setFill(); r.fill()
        Self.label.draw(at: NSPoint(x: r.minX + 6, y: r.minY))
    }
}

/// Under the parent in the thread pane: "3 replies" and a rule.
final class ThreadDividerCellView: NSView {
    static let id = NSUserInterfaceItemIdentifier("threadDivider")
    static let height: CGFloat = 24
    var count = 0 { didSet { if count != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let a = NSAttributedString(string: count == 1 ? "1 reply" : "\(count) replies", attributes: [.font: Theme.Font.small, .foregroundColor: Theme.textMuted])
        let s = a.size()
        let y = (bounds.midY).rounded(.down)
        a.draw(at: NSPoint(x: 20, y: y - s.height / 2))
        Theme.border.setFill()
        NSRect(x: 20 + s.width + 8, y: y, width: max(0, bounds.width - 40 - s.width - 8), height: 1).fill()
    }
}
