import AppKit
import RelayCore

struct PillLayout: Equatable {
    var rect: NSRect
    var name: String
    var glyph: String
    var count: Int
    var mine: Bool
    var users: [String]
}

/// One view per cell that draws every reaction pill itself (§5.6) and hit
/// tests from the same layout. The trailing "add" pill's slot is always
/// reserved; it only draws while the row is hovered or under the cursor.
final class ReactionStrip: NSView, NSViewToolTipOwner {
    static let pillHeight: CGFloat = 24, gap: CGFloat = 4, addWidth: CGFloat = 32
    private static let digit = NSAttributedString(string: "0", attributes: [.font: Theme.Font.smallSemibold]).size().width

    var pills: [PillLayout] = [] { didSet { if pills != oldValue { needsDisplay = true; rebuildTips() } } }
    var addRect: NSRect = .zero
    var showAdd = false { didSet { if showAdd != oldValue { setNeedsDisplay(addRect.insetBy(dx: -2, dy: -2)) } } }
    var hoveredPill: Int? { didSet { if hoveredPill != oldValue { needsDisplay = true } } }
    var onToggle: ((String) -> Void)?
    var onAdd: (() -> Void)?
    var name: (String) -> String = { $0 }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Wraps pills at `width`; returns the layout and the strip's height.
    static func layout(_ reactions: [SlackReaction], me: String?, custom: [String: String], width: CGFloat) -> (pills: [PillLayout], add: NSRect, height: CGFloat) {
        guard !reactions.isEmpty else { return ([], .zero, 0) }
        var x: CGFloat = 0, y: CGFloat = 0
        var out: [PillLayout] = []
        out.reserveCapacity(reactions.count)
        for r in reactions {
            let glyph = EmojiData.glyph(r.name) ?? ":\(r.name):"
            let glyphW: CGFloat = EmojiData.glyph(r.name) != nil ? 18 : NSAttributedString(string: glyph, attributes: [.font: Theme.Font.small]).size().width.rounded(.up)
            let w = 8 + glyphW + 4 + CGFloat(String(r.count).count) * digit + 8
            if x > 0, x + w > width { x = 0; y += pillHeight + gap }
            out.append(PillLayout(rect: NSRect(x: x, y: y, width: w.rounded(.up), height: pillHeight), name: r.name, glyph: glyph,
                                  count: r.count, mine: me.map { (r.users ?? []).contains($0) } ?? false, users: r.users ?? []))
            x += w.rounded(.up) + gap
        }
        if x > 0, x + addWidth > width { x = 0; y += pillHeight + gap }
        return (out, NSRect(x: x, y: y, width: addWidth, height: pillHeight), y + pillHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, p) in pills.enumerated() where p.rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: p.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            (p.mine ? Theme.reactMineBg : Theme.reactBg).setFill()
            path.fill()
            (hoveredPill == i ? Theme.textMuted : p.mine ? Theme.reactMineBorder : Theme.reactBg).setStroke()
            path.lineWidth = 1
            path.stroke()
            let isUnicode = EmojiData.glyph(p.name) != nil
            let g = NSAttributedString(string: p.glyph, attributes: [.font: isUnicode ? Theme.Font.emoji : Theme.Font.small, .foregroundColor: Theme.textMuted])
            let gs = g.size()
            g.draw(at: NSPoint(x: p.rect.minX + 8 + (isUnicode ? (18 - gs.width) / 2 : 0), y: p.rect.minY + (p.rect.height - gs.height) / 2))
            let c = NSAttributedString(string: String(p.count), attributes: [.font: Theme.Font.smallSemibold, .foregroundColor: p.mine ? Theme.reactMineCount : Theme.text])
            let cs = c.size()
            c.draw(at: NSPoint(x: p.rect.maxX - 8 - cs.width, y: p.rect.minY + (p.rect.height - cs.height) / 2))
        }
        if showAdd, addRect.width > 0 {
            let path = NSBezierPath(roundedRect: addRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            Theme.reactBg.setFill()
            path.fill()
            Symbols.draw("face.smiling", 14, color: Theme.textMuted, in: addRect.offsetBy(dx: -2, dy: 0))
            Symbols.draw("plus", 7, .bold, color: Theme.textMuted, in: NSRect(x: addRect.maxX - 13, y: addRect.minY + 3, width: 8, height: 8))
        }
    }

    private func pill(at p: NSPoint) -> Int? { pills.firstIndex { $0.rect.contains(p) } }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = pill(at: p) { onToggle?(pills[i].name) } else if showAdd, addRect.contains(p) { onAdd?() }
    }

    func hover(at windowPoint: NSPoint?) {
        hoveredPill = windowPoint.flatMap { pill(at: convert($0, from: nil)) }
    }

    private func rebuildTips() {
        removeAllToolTips()
        for (i, p) in pills.enumerated() { addToolTip(p.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1)) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let i = pill(at: point) else { return "" }
        let p = pills[i]
        let people = p.users.map(name)
        let who: String
        switch people.count {
        case 0: who = "\(p.count) \(p.count == 1 ? "person" : "people")"
        case 1: who = people[0]
        case 2: who = "\(people[0]) and \(people[1])"
        default: who = people.dropLast().joined(separator: ", ") + " and " + people.last!
        }
        return "\(who) reacted with :\(p.name):"
    }
}
