import AppKit
import RelayCore

/// D§2: the 38pt bar across the window: back/forward and the search pill.
/// Empty parts drag the window.
final class TopBar: NSView {
    var placeholder = "Search" { didSet { needsDisplay = true } }
    var sidebarWidth: CGFloat = Sidebar.width { didSet { needsDisplay = true } }
    var canBack = false { didSet { needsDisplay = true } }
    var canForward = false { didSet { needsDisplay = true } }
    var onSearch: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    static let height: CGFloat = 38
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    private var pill: NSRect {
        let w = min(640, max(280, bounds.width - sidebarWidth - 120))
        return NSRect(x: max(sidebarWidth + 10, (bounds.width - w) / 2), y: 6, width: w, height: 26)
    }
    private var back: NSRect { NSRect(x: max(84, sidebarWidth - 70), y: 5, width: 28, height: 28) }
    private var forward: NSRect { back.offsetBy(dx: 30, dy: 0) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.sbTopBar.setFill()
        bounds.fill()
        let p = pill
        Theme.searchPill.setFill()
        NSBezierPath(roundedRect: p, xRadius: 6, yRadius: 6).fill()
        Glyphs.magnifier(in: NSRect(x: p.minX + 10, y: p.midY - 6, width: 12, height: 12), Theme.textMuted)
        let a = NSAttributedString(string: placeholder, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.textMuted])
        a.draw(at: NSPoint(x: p.minX + 30, y: p.midY - a.size().height / 2))
        chevron(back, left: true, on: canBack)
        chevron(forward, left: false, on: canForward)
    }

    private func chevron(_ r: NSRect, left: Bool, on: Bool) {
        let p = NSBezierPath()
        let dx: CGFloat = left ? 2.5 : -2.5
        p.move(to: NSPoint(x: r.midX + dx, y: r.midY - 5))
        p.line(to: NSPoint(x: r.midX - dx, y: r.midY))
        p.line(to: NSPoint(x: r.midX + dx, y: r.midY + 5))
        p.lineWidth = 1.6
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        Theme.sbText.withAlphaComponent(on ? 1 : 0.4).setStroke()
        p.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if pill.contains(p) { onSearch?() } else if back.contains(p) { onBack?() } else if forward.contains(p) { onForward?() } else { super.mouseDown(with: event) }
    }
}

/// D§4: star, glyph, name, topic, and the search button. 49 high.
final class ChannelHeader: NSView {
    var conversation: Conversation? { didSet { needsDisplay = true } }
    var starred = false { didSet { needsDisplay = true } }
    var avatar: CGImage? { didSet { needsDisplay = true } }
    var title: String? { didSet { needsDisplay = true } }
    var subtitle: String? { didSet { needsDisplay = true } }
    var closable = false
    var onStar: (() -> Void)?
    var onName: (() -> Void)?
    var onSearch: (() -> Void)?
    var onClose: (() -> Void)?
    var onSubtitle: (() -> Void)?
    /// The ⋮ menu: details, copy link, open in Slack (D§4).
    var onMore: ((NSRect) -> Void)?
    static let height: CGFloat = 49
    override var isFlipped: Bool { true }
    private var nameRect = NSRect.zero, subtitleRect = NSRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        NotificationCenter.default.addObserver(forName: Symbols.warmed, object: nil, queue: .main) { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var starRect: NSRect { NSRect(x: 14, y: 11, width: 26, height: 26) }
    private var rightRect: NSRect { NSRect(x: bounds.width - 44, y: 10, width: 28, height: 28) }
    /// Channel headers: search sits 8 left of the ⋮ at the edge.
    private var searchRect: NSRect { closable ? rightRect : rightRect.offsetBy(dx: -36, dy: 0) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        bounds.fill()
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        var x: CGFloat = 20
        let mid = (bounds.height - 1) / 2
        if let title {
            let a = NSAttributedString(string: title, attributes: [.font: Theme.Font.title, .foregroundColor: Theme.textStrong])
            let s = a.size()
            a.draw(at: NSPoint(x: x, y: mid - s.height / 2))
            x += s.width + 10
            if let subtitle {
                let b = NSAttributedString(string: subtitle, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.textMuted])
                let bs = b.size()
                subtitleRect = NSRect(x: x, y: mid - bs.height / 2, width: min(bs.width, rightRect.minX - x - 8), height: bs.height)
                b.draw(with: subtitleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        } else if let c = conversation {
            drawStar()
            x = starRect.maxX + 4
            switch c.kind {
            case .channel, .private:
                if c.kind == .private { Glyphs.lock(in: NSRect(x: x, y: mid - 8, width: 16, height: 16), Theme.textStrong) } else {
                    let g = NSAttributedString(string: "#", attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: Theme.textStrong])
                    g.draw(at: NSPoint(x: x + 2, y: mid - g.size().height / 2))
                }
                x += 18
            case .im, .mpim:
                if let avatar, let ctx = NSGraphicsContext.current?.cgContext {
                    let r = NSRect(x: x, y: mid - 10, width: 20, height: 20)
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
                    ctx.clip()
                    ctx.translateBy(x: 0, y: r.maxY + r.minY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(avatar, in: r)
                    ctx.restoreGState()
                    x += 26
                }
            }
            let a = NSAttributedString(string: c.name, attributes: [.font: Theme.Font.title, .foregroundColor: Theme.textStrong])
            let s = a.size()
            let maxName = max(40, searchRect.minX - x - 40)
            nameRect = NSRect(x: x, y: mid - s.height / 2, width: min(s.width, maxName), height: s.height)
            a.draw(with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            Glyphs.chevronDown(in: NSRect(x: nameRect.maxX + 5, y: mid - 5, width: 10, height: 10), Theme.textMuted)
            x = nameRect.maxX + 24
            if let topic = c.topic, !topic.isEmpty, x < searchRect.minX - 20 {
                let t = NSAttributedString(string: topic, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.textMuted])
                let ts = t.size()
                t.draw(with: NSRect(x: x, y: mid - ts.height / 2 + 1, width: searchRect.minX - x - 8, height: ts.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
        if closable {
            let r = rightRect
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.midX - 5, y: r.midY - 5)); p.line(to: NSPoint(x: r.midX + 5, y: r.midY + 5))
            p.move(to: NSPoint(x: r.midX + 5, y: r.midY - 5)); p.line(to: NSPoint(x: r.midX - 5, y: r.midY + 5))
            p.lineWidth = 1.5; p.lineCapStyle = .round
            Theme.textMuted.setStroke(); p.stroke()
        } else {
            Glyphs.magnifier(in: searchRect.insetBy(dx: 7, dy: 7), Theme.textMuted)
            Theme.textMuted.setFill()
            for i in -1...1 {
                NSBezierPath(ovalIn: NSRect(x: rightRect.midX - 1.6, y: rightRect.midY + CGFloat(i) * 5 - 1.6, width: 3.2, height: 3.2)).fill()
            }
        }
    }

    private func drawStar() {
        let r = starRect.insetBy(dx: 5, dy: 5)
        let p = NSBezierPath()
        for i in 0..<10 {
            let a = CGFloat(i) * .pi / 5 - .pi / 2
            let rad = i % 2 == 0 ? r.width / 2 : r.width / 4.6
            let pt = NSPoint(x: r.midX + cos(a) * rad, y: r.midY + sin(a) * rad)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        p.lineJoinStyle = .round
        if starred { Theme.star.setFill(); p.fill() } else { p.lineWidth = 1.3; Theme.textMuted.setStroke(); p.stroke() }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closable, rightRect.contains(p) { onClose?(); return }
        if !closable, searchRect.contains(p) { onSearch?(); return }
        if !closable, rightRect.contains(p) { onMore?(rightRect); return }
        if title == nil, starRect.contains(p) { onStar?(); return }
        if title == nil, nameRect.insetBy(dx: -4, dy: -6).contains(p) { onName?(); return }
        if title != nil, subtitleRect.contains(p) { onSubtitle?() }
    }
}
