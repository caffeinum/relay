import AppKit
import RelayCore

extension NSAttributedString.Key {
    /// A rounded background behind a run: inline code, mentions, bare links.
    static let relayChip = NSAttributedString.Key("relayChip")
    /// A block decoration: the code block card or the quote bar.
    static let relayBlock = NSAttributedString.Key("relayBlock")
    /// A click target. Not `.link`: TextKit would underline it and paint it system blue.
    static let relayLink = NSAttributedString.Key("relayLink")
}

enum Chip: Int { case code, mention, mentionMe, link }
enum BlockDeco: Int { case code, quote }

/// Names the body needs, resolved on the main thread before building.
struct ResolvedNames {
    var users: [String: String] = [:]
    var channels: [String: String] = [:]
    var groups: [String: String] = [:]
    var custom: [String: String] = [:]
    var me: String?
}

/// A message's body as one attributed string (§5.5), built off main from
/// parsed blocks. Built once per message version; never on hover or cursor moves.
struct Body {
    var text: NSAttributedString
    var mentionsMe: Bool
    var links: [(label: String, url: URL)]

    static let lineHeight: CGFloat = 20

    private static func para(_ indent: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 0, tail: CGFloat = 0, line: CGFloat = lineHeight) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = line
        p.headIndent = indent
        p.firstLineHeadIndent = indent
        p.tailIndent = tail
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineBreakMode = .byWordWrapping
        return p
    }

    /// Bullets and numbers share one text column at 22; the marker is
    /// right-aligned at 16, so "10." fits and "•" lines up with "1.".
    static func listPara(_ quoted: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.firstLineHeadIndent = quoted
        p.headIndent = quoted + 22
        p.tabStops = [NSTextTab(textAlignment: .right, location: quoted + 16), NSTextTab(textAlignment: .left, location: quoted + 22)]
        p.paragraphSpacing = 2
        p.lineBreakMode = .byWordWrapping
        return p
    }

    static let pBody = para()
    static let pCode = para(9, before: 12, after: 12, tail: -9, line: 18)
    static let pJumbo = para(line: 36)

    static let linkIcon: NSImage = Glyphs.link(Theme.link)

    /// Collects the ids the blocks mention, so the main thread can resolve them in one pass.
    static func ids(_ blocks: [Mrkdwn.Block], into r: inout (users: Set<String>, channels: Set<String>, groups: Set<String>)) {
        func walk(_ xs: [Mrkdwn.Inline]) {
            for x in xs {
                switch x {
                case .mention(.user(let id, nil)): r.users.insert(id)
                case .mention(.channel(let id, nil)): r.channels.insert(id)
                case .mention(.group(let id, nil)): r.groups.insert(id)
                case .bold(let c), .italic(let c), .strike(let c): walk(c)
                default: break
                }
            }
        }
        for b in blocks {
            switch b {
            case .paragraph(let xs): walk(xs)
            case .quote(let inner): ids(inner, into: &r)
            case .list(_, let items): items.forEach(walk)
            case .code: break
            }
        }
    }

    private struct Style { var bold = false, italic = false, strike = false }

    static func build(_ blocks: [Mrkdwn.Block], edited: Bool, names: ResolvedNames, dim: Bool = false) -> Body {
        let out = NSMutableAttributedString()
        var mentionsMe = false
        var links: [(String, URL)] = []
        let textColor = Theme.text

        func font(_ s: Style) -> NSFont {
            switch (s.bold, s.italic) {
            case (true, true): return Theme.Font.bodyBoldItalic
            case (true, false): return Theme.Font.bodyBold
            case (false, true): return Theme.Font.bodyItalic
            default: return Theme.Font.body
            }
        }
        func attrs(_ s: Style, _ p: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [.font: font(s), .foregroundColor: s.strike ? Theme.textMuted : s.bold ? Theme.textStrong : textColor, .paragraphStyle: p]
            if s.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return a
        }
        func chip(_ string: String, _ a: [NSAttributedString.Key: Any], _ kind: Chip) {
            if out.length > 0 {
                let prev = NSRange(location: out.length - 1, length: 1)
                if (out.attribute(.relayChip, at: prev.location, effectiveRange: nil) == nil) { out.addAttribute(.kern, value: 4, range: prev) }
            }
            var a = a
            a[.relayChip] = kind.rawValue
            let start = out.length
            out.append(NSAttributedString(string: string, attributes: a))
            if out.length > start { out.addAttribute(.kern, value: 4, range: NSRange(location: out.length - 1, length: 1)) }
        }
        func inline(_ xs: [Mrkdwn.Inline], _ s: Style, _ p: NSParagraphStyle) {
            for x in xs {
                switch x {
                case .text(let t): out.append(NSAttributedString(string: t, attributes: attrs(s, p)))
                case .bold(let c): var n = s; n.bold = true; inline(c, n, p)
                case .italic(let c): var n = s; n.italic = true; inline(c, n, p)
                case .strike(let c): var n = s; n.strike = true; inline(c, n, p)
                case .code(let t):
                    chip(t, [.font: Theme.Font.mono, .foregroundColor: Theme.codeInline, .paragraphStyle: p, .baselineOffset: 0.5], .code)
                case .emoji(let n):
                    if let g = EmojiData.glyph(n) { out.append(NSAttributedString(string: g, attributes: attrs(s, p))) }
                    else { out.append(NSAttributedString(string: ":\(n):", attributes: attrs(s, p))) }
                case .mention(let ref):
                    let label: String, me: Bool, url: String
                    switch ref {
                    case .user(let id, let l):
                        label = "@" + (l ?? names.users[id] ?? id); me = id == names.me; url = "relay-user:\(id)"
                    case .channel(let id, let l):
                        label = "#" + (l ?? names.channels[id] ?? id); me = false; url = "relay-channel:\(id)"
                    case .group(let id, let l):
                        let h = l ?? names.groups[id].map { "@" + $0 } ?? "@\(id)"
                        label = h.hasPrefix("@") ? h : "@" + h; me = false; url = "relay-group:\(id)"
                    case .special(let n):
                        label = "@" + n; me = ["here", "channel", "everyone"].contains(n); url = "relay-special:\(n)"
                    }
                    if me { mentionsMe = true }
                    var a: [NSAttributedString.Key: Any] = [.font: Theme.Font.bodyMedium, .foregroundColor: me ? Theme.mentionMeFg : Theme.mentionFg, .paragraphStyle: p]
                    if let u = URL(string: url) { a[.relayLink] = u }
                    chip(label, a, me ? .mentionMe : .mention)
                case .link(let label, let raw):
                    guard let url = URL(string: raw) else {
                        out.append(NSAttributedString(string: label ?? raw, attributes: attrs(s, p)))
                        continue
                    }
                    links.append((label ?? raw, url))
                    if let label {
                        var a = attrs(s, p)
                        a[.foregroundColor] = Theme.link
                        a[.relayLink] = url
                        out.append(NSAttributedString(string: label, attributes: a))
                    } else {
                        var a = attrs(s, p)
                        a[.foregroundColor] = Theme.link
                        a[.relayLink] = url
                        // The icon is drawn by BodyLayoutManager into the kern of a leading no-break space,
                        // so the line stays measurable without an attachment.
                        let start = out.length
                        chip("\u{202F}" + unbreakable(short(raw)), a, .link)
                        out.addAttribute(.kern, value: 17, range: NSRange(location: start, length: 1))
                    }
                }
            }
        }
        func newline(_ p: NSParagraphStyle) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.Font.body, .paragraphStyle: p])) }
        }
        func emit(_ bs: [Mrkdwn.Block], quoted: CGFloat) {
            for b in bs {
                switch b {
                case .paragraph(let xs):
                    let p = quoted > 0 ? para(quoted) : (isJumbo(bs) ? pJumbo : pBody)
                    newline(p)
                    let start = out.length
                    inline(xs, Style(), p)
                    if isJumbo(bs) { out.addAttribute(.font, value: Theme.Font.jumbo, range: NSRange(location: start, length: out.length - start)) }
                    if quoted > 0 { out.addAttribute(.relayBlock, value: BlockDeco.quote.rawValue, range: NSRange(location: start, length: out.length - start)) }
                case .quote(let inner):
                    emit(inner, quoted: quoted + 14)
                case .code(let t):
                    newline(pCode)
                    let body = t.isEmpty ? " " : t.replacingOccurrences(of: "\n", with: "\u{2028}")
                    out.append(NSAttributedString(string: body, attributes: [.font: Theme.Font.mono, .foregroundColor: textColor, .paragraphStyle: pCode,
                                                                                .relayBlock: BlockDeco.code.rawValue]))
                case .list(let ordered, let items):
                    let p = listPara(quoted)
                    for (i, item) in items.enumerated() {
                        newline(p)
                        let start = out.length
                        out.append(NSAttributedString(string: "\t" + (ordered ? "\(i + 1)." : "•") + "\t", attributes: attrs(Style(), p)))
                        inline(item, Style(), p)
                        if quoted > 0 { out.addAttribute(.relayBlock, value: BlockDeco.quote.rawValue, range: NSRange(location: start, length: out.length - start)) }
                    }
                }
            }
        }
        emit(blocks, quoted: 0)
        if edited {
            let lastIsBlock = out.length > 0 && out.attribute(.relayBlock, at: out.length - 1, effectiveRange: nil) != nil
            if lastIsBlock { newline(pBody) }
            out.append(NSAttributedString(string: (lastIsBlock ? "" : " ") + "(edited)", attributes: [.font: Theme.Font.meta, .foregroundColor: Theme.textMuted, .paragraphStyle: pBody]))
        }
        if dim { out.addAttribute(.foregroundColor, value: Theme.textMuted, range: NSRange(location: 0, length: out.length)) }
        return Body(text: out, mentionsMe: mentionsMe, links: links)
    }

    /// One to three emoji and nothing else: drawn at 28pt.
    static func isJumbo(_ bs: [Mrkdwn.Block]) -> Bool {
        guard bs.count == 1, case .paragraph(let xs) = bs[0] else { return false }
        var n = 0
        for x in xs {
            switch x {
            case .emoji(let e): guard EmojiData.glyph(e) != nil else { return false }; n += 1
            case .text(let t): guard t.allSatisfy(\.isWhitespace) else { return false }
            default: return false
            }
        }
        return (1...3).contains(n)
    }

    /// A word joiner after each separator, so a link chip moves to the next
    /// line whole instead of breaking at "/" and leaving its capsule behind.
    static func unbreakable(_ s: String) -> String {
        var out = ""
        for c in s {
            out.append(c)
            if "/.-?&=_#:".contains(c) { out.append("\u{2060}") }
        }
        return out
    }

    /// "docs.revyl.com/infrastructure": no scheme, at most 48 characters with a middle "…".
    static func short(_ url: String) -> String {
        var s = url
        for p in ["https://", "http://", "mailto:"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        guard s.count > 48 else { return s }
        return String(s.prefix(30)) + "…" + String(s.suffix(17))
    }
}

/// Draws the rounded chips and block decorations behind the text in the
/// same pass as the glyphs: no extra views.
final class BodyLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.relayBlock, in: all) { value, range, _ in
            guard let raw = value as? Int, let deco = BlockDeco(rawValue: raw) else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let first = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let last = lineFragmentRect(forGlyphAt: NSMaxRange(gr) - 1, effectiveRange: nil)
            switch deco {
            case .code:
                let r = NSRect(x: origin.x + 0.5, y: origin.y + first.minY + 4.5, width: container.size.width - 1, height: last.maxY - first.minY - 9)
                let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                Theme.codeBg.setFill(); path.fill()
                Theme.codeBorder.setStroke(); path.lineWidth = 1; path.stroke()
            case .quote:
                let r = NSRect(x: origin.x, y: origin.y + first.minY, width: 4, height: last.maxY - first.minY)
                Theme.quoteBar.setFill()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            }
        }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.relayChip, in: chars) { value, range, _ in
            guard let raw = value as? Int, let chip = Chip(rawValue: raw) else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var first = true
            enumerateEnclosingRects(forGlyphRange: gr, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                defer { first = false }
                // The run's last character carries 4pt of kern: 2 of it pads the chip, 2 separate it.
                let r = rect.offsetBy(dx: origin.x - 2, dy: origin.y).insetBy(dx: 0, dy: 1.5)
                let radius: CGFloat = chip == .link ? 4 : 3
                let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
                switch chip {
                case .code:
                    Theme.codeBg.setFill(); path.fill()
                    Theme.codeBorder.setStroke(); path.lineWidth = 1; path.stroke()
                case .mention: Theme.mentionBg.setFill(); path.fill()
                case .mentionMe: Theme.mentionMeBg.setFill(); path.fill()
                case .link:
                    Theme.linkChipBg.setFill(); path.fill()
                    if first {
                        let icon = Body.linkIcon
                        icon.draw(in: NSRect(x: r.minX + 4, y: r.midY - 6, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                }
            }
        }
    }
}

/// One TextKit stack per thread, measuring bodies at a width.
final class Measurer {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    func height(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        guard s.length > 0 else { return 0 }
        if let h = Self.singleLine(s, width: width) { return h }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(s)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    /// Most messages are one short line: a CoreText width check answers
    /// those without a layout pass. Anything with lines, blocks,
    /// attachments or jumbo emoji goes through TextKit.
    static func singleLine(_ s: NSAttributedString, width: CGFloat) -> CGFloat? {
        let ns = s.string as NSString
        guard ns.rangeOfCharacter(from: breaks).location == NSNotFound else { return nil }
        var plain = true
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { a, _, stop in
            if a[.relayBlock] != nil || a[.attachment] != nil || (a[.font] as? NSFont)?.pointSize ?? 0 > 20 { plain = false; stop.pointee = true }
        }
        guard plain else { return nil }
        let line = CTLineCreateWithAttributedString(s)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        return w <= Double(width) - 2 ? Body.lineHeight : nil
    }

    private static let breaks = CharacterSet(charactersIn: "\n\u{2028}\u{2029}\u{FFFC}")
}
