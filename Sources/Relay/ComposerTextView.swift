import AppKit
import RelayCore

extension NSAttributedString.Key {
    /// A mention token in a composer: atomic, encoded as <@U…> on send.
    static let relayMention = NSAttributedString.Key("relayMention")
}

final class MentionAttr: NSObject {
    let target: MentionTarget
    let label: String
    init(_ target: MentionTarget, _ label: String) { self.target = target; self.label = label }
}

/// One row of the @ # : popup.
struct Suggestion {
    enum Insert { case token(MentionTarget, String), text(String) }
    var title: String
    var detail: String
    var tag: String?
    var glyph: String?
    var avatar: (id: String, url: String?)?
    var insert: Insert
}

/// The composer's text (D§7), shared with edit in place: mention tokens as
/// atomic attributes, live styling of the edited paragraph only, ⌘B ⌘I
/// ⌘⇧X ⌘⇧C, and the @ # : popup.
final class ComposerTextView: NSTextView, NSTextStorageDelegate {
    var placeholder = "" { didSet { needsDisplay = true } }
    /// (sigil, query) → rows. "@" people, bots, groups; "#" channels; ":" emoji.
    var complete: ((Character, String) -> [Suggestion])?
    var onCommandReturn: (() -> Void)?
    var onUndoEmpty: (() -> Bool)?
    weak var popupHost: NSView?
    private let popup = CompletionPopup()
    private var trigger: (range: NSRange, sigil: Character)?

    static var base: [NSAttributedString.Key: Any] { [.font: Theme.Font.body, .foregroundColor: Theme.text] }
    private static let mention: [NSAttributedString.Key: Any] = [.font: Theme.Font.bodyMedium, .foregroundColor: Theme.mentionFg, .backgroundColor: Theme.mentionBg]

    convenience init() {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        lm.addTextContainer(tc)
        self.init(frame: NSRect(x: 0, y: 0, width: 300, height: 20), textContainer: tc)
        storage.delegate = self
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        drawsBackground = false
        font = Theme.Font.body
        textColor = Theme.text
        insertionPointColor = Theme.textStrong
        typingAttributes = Self.base
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        popup.onPick = { [weak self] s in self?.accept(s) }
    }

    // MARK: tokens

    var tokens: [MentionToken] {
        var out: [MentionToken] = []
        textStorage?.enumerateAttribute(.relayMention, in: NSRange(location: 0, length: textStorage?.length ?? 0)) { v, r, _ in
            if let m = v as? MentionAttr { out.append(MentionToken(range: r, target: m.target, label: m.label)) }
        }
        return out
    }

    /// What Slack gets: the text with tokens as <@U>, & < > escaped elsewhere (K3).
    var mrkdwn: String { Mentions.encode(string, tokens: tokens) }

    func load(_ text: String, tokens: [MentionToken], selection: NSRange? = nil) {
        let a = NSMutableAttributedString(string: text, attributes: Self.base)
        for t in tokens where NSMaxRange(t.range) <= a.length {
            a.addAttributes(Self.mention, range: t.range)
            a.addAttribute(.relayMention, value: MentionAttr(t.target, t.label), range: t.range)
        }
        textStorage?.setAttributedString(a)
        restyle(NSRange(location: 0, length: a.length))
        let end = NSRange(location: a.length, length: 0)
        let sel = selection.map { NSMaxRange($0) <= a.length ? $0 : end } ?? end
        setSelectedRange(sel)
        typingAttributes = Self.base
        undoManager?.removeAllActions()
        closePopup()
        didChangeText()
    }

    /// The atom goes whole: backspace right after a token deletes all of it.
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0, let r = tokenRange(at: sel.location - 1) {
            insertText("", replacementRange: r)
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, let r = tokenRange(at: sel.location) {
            insertText("", replacementRange: r)
            return
        }
        super.deleteForward(sender)
    }

    private func tokenRange(at i: Int) -> NSRange? {
        guard let ts = textStorage, i >= 0, i < ts.length else { return nil }
        var r = NSRange()
        guard ts.attribute(.relayMention, at: i, longestEffectiveRange: &r, in: NSRange(location: 0, length: ts.length)) != nil else { return nil }
        return r
    }

    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        typingAttributes = Self.base
        return super.shouldChangeText(in: range, replacementString: replacementString)
    }

    // MARK: live styling (D§7, K4)

    func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        // a token whose text was edited inside stops being a token
        ts.enumerateAttribute(.relayMention, in: (ts.string as NSString).paragraphRange(for: range)) { v, r, _ in
            guard let m = v as? MentionAttr, (ts.string as NSString).substring(with: r) != m.label else { return }
            ts.removeAttribute(.relayMention, range: r)
        }
        restyle((ts.string as NSString).paragraphRange(for: range), storage: ts)
    }

    private static let inline: [(NSRegularExpression, [NSAttributedString.Key: Any])] = [
        (try! NSRegularExpression(pattern: "(?<![\\w*])\\*[^*\\n]+\\*(?![\\w*])"), [.font: Theme.Font.bodyBold, .foregroundColor: Theme.textStrong]),
        (try! NSRegularExpression(pattern: "(?<![\\w_])_[^_\\n]+_(?![\\w_])"), [.font: Theme.Font.bodyItalic]),
        (try! NSRegularExpression(pattern: "(?<![\\w~])~[^~\\n]+~(?![\\w~])"), [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Theme.textMuted]),
        (try! NSRegularExpression(pattern: "`[^`\\n]+`"), [.font: Theme.Font.mono, .foregroundColor: Theme.codeInline]),
    ]

    func restyle(_ para: NSRange, storage: NSTextStorage? = nil) {
        guard let ts = storage ?? textStorage, para.length > 0 else { return }
        let ns = ts.string as NSString
        let fenced = insideFence(at: para.location, ns) || ns.substring(with: para).hasPrefix("```")
        ts.enumerateAttribute(.relayMention, in: para) { v, r, _ in
            if v == nil {
                ts.setAttributes(fenced ? [.font: Theme.Font.mono, .foregroundColor: Theme.text] : Self.base, range: r)
            } else {
                ts.addAttributes(Self.mention, range: r)
            }
        }
        guard !fenced else { return }
        let text = ns.substring(with: para)
        for (re, attrs) in Self.inline {
            for m in re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let r = NSRange(location: para.location + m.range.location, length: m.range.length)
                if ts.attribute(.relayMention, at: r.location, effectiveRange: nil) != nil { continue }
                ts.addAttributes(attrs, range: r)
                ts.addAttribute(.foregroundColor, value: Theme.textFaint, range: NSRange(location: r.location, length: 1))
                ts.addAttribute(.foregroundColor, value: Theme.textFaint, range: NSRange(location: NSMaxRange(r) - 1, length: 1))
            }
        }
    }

    /// An odd number of ``` before `i` means `i` is inside a fence.
    func insideFence(at i: Int, _ ns: NSString? = nil) -> Bool {
        let s = (ns ?? (string as NSString)).substring(to: min(i, (ns ?? (string as NSString)).length))
        return s.components(separatedBy: "```").count % 2 == 0
    }

    var caretInFence: Bool { insideFence(at: selectedRange().location) }

    // MARK: formatting keys (K4)

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: e) }
        let shift = e.modifierFlags.contains(.shift)
        switch (e.charactersIgnoringModifiers?.lowercased(), shift) {
        case ("b", false): wrap("*"); return true
        case ("i", false): wrap("_"); return true
        case ("x", true): wrap("~"); return true
        case ("c", true): wrap("`"); return true
        case ("z", false) where string.isEmpty: if onUndoEmpty?() == true { return true }
        default: break
        }
        if e.keyCode == 36 || e.keyCode == 76 { onCommandReturn?(); return true }
        return super.performKeyEquivalent(with: e)
    }

    func wrap(_ marker: String) {
        let sel = selectedRange()
        let inner = (string as NSString).substring(with: sel)
        insertText(marker + inner + marker, replacementRange: sel)
        if sel.length == 0 { setSelectedRange(NSRange(location: sel.location + marker.utf16.count, length: 0)) }
    }

    // MARK: placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        NSAttributedString(string: placeholder, attributes: [.font: Theme.Font.body, .foregroundColor: Theme.textMuted]).draw(at: NSPoint(x: 0, y: 0))
    }

    // MARK: autocomplete (D§7.1)

    override func didChangeText() {
        super.didChangeText()
        updateTrigger()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting, popup.superview != nil { updateTrigger() }
    }

    private func updateTrigger() {
        guard complete != nil, window != nil else { closePopup(); return }
        let sel = selectedRange()
        guard sel.length == 0 else { closePopup(); return }
        let ns = string as NSString
        var i = sel.location
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == 32 || c == 10 || c == 9 { break }
            i -= 1
            if c == 64 || c == 35 || c == 58 { break }
        }
        guard i < sel.location, tokenRange(at: i) == nil else { closePopup(); return }
        let sigil = Character(UnicodeScalar(ns.character(at: i))!)
        guard "@#:".contains(sigil), i == 0 || [32, 10, 9, 40].contains(ns.character(at: i - 1)) else { closePopup(); return }
        let q = ns.substring(with: NSRange(location: i + 1, length: sel.location - i - 1))
        if sigil == ":" && q.count < 2 { closePopup(); return }
        if q.contains(where: { $0 == ":" || $0 == "@" || $0 == "#" }) { closePopup(); return }
        let rows = complete?(sigil, q) ?? []
        guard !rows.isEmpty else { closePopup(); return }
        trigger = (NSRange(location: i, length: sel.location - i), sigil)
        showPopup(rows, at: i)
    }

    private func showPopup(_ rows: [Suggestion], at i: Int) {
        guard let host = popupHost ?? window?.contentView, let lm = layoutManager, let tc = textContainer else { return }
        let g = lm.glyphIndexForCharacter(at: min(i, max(0, (string as NSString).length - 1)))
        var r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        if (string as NSString).length == 0 { r = .zero }
        let inView = r.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let p = host.convert(inView, from: self)
        popup.rows = rows
        if popup.superview !== host { host.addSubview(popup) }
        let h = popup.preferredHeight
        let top = host.isFlipped ? p.minY - 6 - h : p.maxY + 6
        let x = max(8, min(p.minX - 10, host.bounds.width - CompletionPopup.width - 8))
        popup.frame = NSRect(x: x, y: max(4, top), width: CompletionPopup.width, height: h)
        popup.needsDisplay = true
    }

    func closePopup() {
        trigger = nil
        popup.removeFromSuperview()
    }

    var popupOpen: Bool { popup.superview != nil }

    private func accept(_ s: Suggestion) {
        guard let t = trigger else { return }
        closePopup()
        switch s.insert {
        case .text(let text):
            insertText(text, replacementRange: t.range)
        case .token(let target, let label):
            let shown = (t.sigil == "#" ? "#" : "@") + label
            guard shouldChangeText(in: t.range, replacementString: shown + " ") else { return }
            let a = NSMutableAttributedString(string: shown, attributes: Self.mention)
            a.addAttribute(.relayMention, value: MentionAttr(target, shown), range: NSRange(location: 0, length: a.length))
            a.append(NSAttributedString(string: " ", attributes: Self.base))
            textStorage?.replaceCharacters(in: t.range, with: a)
            setSelectedRange(NSRange(location: t.range.location + a.length, length: 0))
            typingAttributes = Self.base
            didChangeText()
        }
    }

    override func doCommand(by selector: Selector) {
        if popupOpen {
            switch selector {
            case #selector(moveDown(_:)): popup.move(1); return
            case #selector(moveUp(_:)): popup.move(-1); return
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                if let s = popup.current { accept(s) }
                return
            case #selector(cancelOperation(_:)): closePopup(); return
            default: break
            }
        }
        super.doCommand(by: selector)
    }

    override func resignFirstResponder() -> Bool {
        closePopup()
        return super.resignFirstResponder()
    }
}

/// The popup over the caret: at most 8 rows of 32, drawn.
final class CompletionPopup: NSView {
    static let width: CGFloat = 320, rowHeight: CGFloat = 32
    var rows: [Suggestion] = [] { didSet { index = 0; needsDisplay = true } }
    private(set) var index = 0
    var onPick: ((Suggestion) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredHeight: CGFloat { CGFloat(min(rows.count, 8)) * Self.rowHeight + 8 }
    var current: Suggestion? { rows.indices.contains(index) ? rows[index] : nil }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        index = (index + d + min(rows.count, 8)) % min(rows.count, 8)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if let l = layer { Theme.floatShadow(l, radius: 8, dark: Theme.isDark(self)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.bgRaised.setFill(); box.fill()
        Theme.border.setStroke(); box.lineWidth = 1; box.stroke()
        for (i, s) in rows.prefix(8).enumerated() {
            let r = NSRect(x: 4, y: 4 + CGFloat(i) * Self.rowHeight, width: bounds.width - 8, height: Self.rowHeight)
            if i == index {
                Theme.cursorTint.setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                Theme.cursor.setFill()
                NSRect(x: r.minX, y: r.minY + 4, width: 2, height: r.height - 8).fill()
            }
            let icon = NSRect(x: r.minX + 10, y: r.midY - 10, width: 20, height: 20)
            if let a = s.avatar, let ctx = NSGraphicsContext.current?.cgContext {
                let img = Avatars.shared.layerContents(for: a.id, name: s.title, url: a.url, size: 20)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: icon, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.clip()
                ctx.translateBy(x: 0, y: icon.maxY + icon.minY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: icon)
                ctx.restoreGState()
            } else if let g = s.glyph {
                let a = NSAttributedString(string: g, attributes: [.font: NSFont.systemFont(ofSize: g.count == 1 && g.unicodeScalars.first!.value < 128 ? 14 : 16, weight: .semibold), .foregroundColor: Theme.textMuted])
                let sz = a.size()
                a.draw(at: NSPoint(x: icon.midX - sz.width / 2, y: icon.midY - sz.height / 2))
            }
            var x = icon.maxX + 8
            let title = NSAttributedString(string: s.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.textStrong])
            let ts = title.size()
            let tagW: CGFloat = s.tag == nil ? 0 : 40
            title.draw(with: NSRect(x: x, y: r.midY - ts.height / 2, width: min(ts.width, r.maxX - x - tagW - 8), height: ts.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x += min(ts.width, r.maxX - x - tagW - 8) + 6
            let d = NSAttributedString(string: s.detail, attributes: [.font: Theme.Font.small, .foregroundColor: Theme.textMuted])
            let dsz = d.size()
            if x < r.maxX - tagW - 12 {
                d.draw(with: NSRect(x: x, y: r.midY - dsz.height / 2, width: r.maxX - tagW - 8 - x, height: dsz.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            if let tag = s.tag {
                let t = NSAttributedString(string: tag, attributes: [.font: Theme.Font.tag, .foregroundColor: Theme.textMuted])
                let tsz = t.size()
                let tr = NSRect(x: r.maxX - 10 - tsz.width - 8, y: r.midY - 8, width: tsz.width + 8, height: 16)
                Theme.codeBg.setFill()
                NSBezierPath(roundedRect: tr, xRadius: 3, yRadius: 3).fill()
                t.draw(at: NSPoint(x: tr.minX + 4, y: tr.midY - tsz.height / 2))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int((p.y - 4) / Self.rowHeight)
        if rows.indices.contains(i) { onPick?(rows[i]) }
    }
}
