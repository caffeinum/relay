import AppKit
import RelayCore

/// The message box under a list (D§7): grows with its text, ↩ sends, ⇧↩ adds
/// a line (inside a ``` fence ↩ adds a line and ⌘↩ sends), ↑ when empty
/// edits my last message, esc leaves. The draft autosaves 300 ms after the
/// last keystroke and whenever the key changes.
final class Composer: NSView, NSTextViewDelegate {
    let textView = ComposerTextView()
    private let scroll = NSScrollView()
    private let toolbar = ComposerToolbar()
    private var height: NSLayoutConstraint!
    private var saveWork: DispatchWorkItem?
    private(set) var key: (channel: String, thread: String?) = ("", nil)

    var onSend: ((String) -> Void)?
    var onEditLast: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSaveDraft: ((Draft) -> Void)?
    var onUndoEmpty: (() -> Bool)?
    var onEmoji: (() -> Void)?
    var readOnly = false { didSet { toolbar.readOnly = readOnly; relayout() } }
    var maxHeight: CGFloat = 300

    static let minBox: CGFloat = 42, toolbarHeight: CGFloat = 36
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        textView.delegate = self
        textView.onCommandReturn = { [weak self] in self?.send() }
        textView.onUndoEmpty = { [weak self] in self?.onUndoEmpty?() ?? false }
        addSubview(scroll)
        addSubview(toolbar)
        toolbar.onAction = { [weak self] a in self?.toolbarAction(a) }
        height = heightAnchor.constraint(equalToConstant: Self.minBox)
        height.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (Theme.isDark(self) ? Theme.bgHover : Theme.bg).cgColor
        layer?.borderColor = (focused ? Theme.borderStrong : Theme.border).cgColor
    }

    var focused: Bool { window?.firstResponder === textView }
    var isEmpty: Bool { textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var placeholder: String { get { textView.placeholder } set { textView.placeholder = newValue } }

    func focus() { window?.makeFirstResponder(textView) }

    /// Saves the outgoing key's draft, then shows `draft` for the new key.
    func switchTo(channel: String, thread: String?, draft: Draft?, decode: (String) -> (String, [MentionToken])) {
        flushDraft()
        key = (channel, thread)
        if let d = draft {
            let (text, tokens) = decode(d.text)
            textView.load(text, tokens: tokens, selection: d.selection)
        } else {
            textView.load("", tokens: [])
        }
        relayout()
    }

    var draft: Draft { Draft(channel: key.channel, threadTS: key.thread, text: textView.mrkdwn, selection: textView.selectedRange()) }

    /// A pending debounced save goes out now.
    func flushDraft() {
        guard let w = saveWork else { return }
        w.cancel()
        saveWork = nil
        if !key.channel.isEmpty { onSaveDraft?(draft) }
    }

    /// After a send: the outbox cleared the draft row in the same
    /// transaction, so nothing pending may write it back.
    func clear() {
        saveWork?.cancel()
        saveWork = nil
        textView.load("", tokens: [])
        relayout()
    }

    /// Undo of a send puts its text back.
    func put(_ text: String, tokens: [MentionToken]) {
        textView.load(text, tokens: tokens)
        relayout()
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.saveWork = nil
            if !self.key.channel.isEmpty { self.onSaveDraft?(self.draft) }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func send() {
        guard !isEmpty else { return }
        onSend?(textView.mrkdwn.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func textDidChange(_ notification: Notification) {
        relayout()
        scheduleSave()
    }

    func textDidBeginEditing(_ notification: Notification) { relayout() }
    func textDidEndEditing(_ notification: Notification) { relayout() }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            if shift || textView.caretInFence { tv.insertNewlineIgnoringFieldEditor(nil); return true }
            send()
            return true
        case #selector(NSResponder.moveUp(_:)):
            if tv.string.isEmpty { onEditLast?(); return true }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        default:
            return false
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        guard let w = window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(responderMaybeChanged), name: NSWindow.didUpdateNotification, object: w)
    }

    private var wasFocused = false
    @objc private func responderMaybeChanged() {
        let f = focused
        guard f != wasFocused else { return }
        wasFocused = f
        relayout()
    }

    private var showsToolbar: Bool { readOnly || focused || !textView.string.isEmpty }

    func relayout() {
        needsDisplay = true
        needsLayout = true
        let textH: CGFloat
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            tc.size = NSSize(width: max(40, bounds.width - 24), height: .greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
            textH = max(Body.lineHeight, ceil(lm.usedRect(for: tc).height))
        } else {
            textH = Body.lineHeight
        }
        let box = max(Self.minBox, min(textH, maxHeight) + 22)
        let h = box + (showsToolbar ? Self.toolbarHeight : 0)
        if height.constant != h { height.constant = h }
        toolbar.isHidden = !showsToolbar
        toolbar.hasText = !isEmpty
        updateLayer()
    }

    override func layout() {
        super.layout()
        let tb = showsToolbar ? Self.toolbarHeight : 0
        scroll.frame = NSRect(x: 12, y: 11, width: bounds.width - 24, height: bounds.height - 22 - tb)
        textView.frame.size.width = scroll.contentSize.width
        toolbar.frame = NSRect(x: 6, y: bounds.height - tb, width: bounds.width - 12, height: tb)
    }

    override func setFrameSize(_ s: NSSize) {
        let changed = s.width != frame.width
        super.setFrameSize(s)
        if changed { relayout() }
    }

    private func toolbarAction(_ a: ComposerToolbar.Action) {
        focus()
        switch a {
        case .bold: textView.wrap("*")
        case .italic: textView.wrap("_")
        case .strike: textView.wrap("~")
        case .code: textView.wrap("`")
        case .list: textView.insertText("• ", replacementRange: textView.selectedRange())
        case .emoji: textView.insertText(":", replacementRange: textView.selectedRange())
        case .mention: textView.insertText("@", replacementRange: textView.selectedRange())
        case .send: send()
        }
    }

    override func mouseDown(with event: NSEvent) { focus() }
}

/// D§7's toolbar row, drawn: format buttons, emoji, @, and the send button.
final class ComposerToolbar: NSView {
    enum Action { case bold, italic, strike, code, list, emoji, mention, send }
    var onAction: ((Action) -> Void)?
    var hasText = false { didSet { if hasText != oldValue { needsDisplay = true } } }
    var readOnly = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    private let items: [(Action, String)] = [(.bold, "bold"), (.italic, "italic"), (.strike, "strikethrough"),
                                             (.code, "chevron.left.forwardslash.chevron.right"), (.list, "list.bullet"),
                                             (.emoji, "face.smiling"), (.mention, "at")]

    private func rects() -> [(Action, String, NSRect)] {
        var x: CGFloat = 0
        var out: [(Action, String, NSRect)] = []
        for (i, it) in items.enumerated() {
            if i == 5 { x += 9 }
            out.append((it.0, it.1, NSRect(x: x, y: 4, width: 28, height: 28)))
            x += 30
        }
        return out
    }

    private var sendRect: NSRect { NSRect(x: bounds.width - 30, y: 4, width: 28, height: 28) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(forName: Symbols.warmed, object: nil, queue: .main) { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if readOnly {
            let a = NSAttributedString(string: "Read-only workspace: writes are off", attributes: [.font: Theme.Font.small, .foregroundColor: Theme.textMuted])
            Glyphs.lock(in: NSRect(x: 4, y: 10, width: 16, height: 16), Theme.textMuted)
            a.draw(at: NSPoint(x: 24, y: (bounds.height - a.size().height) / 2))
            return
        }
        guard Symbols.ready else { return }
        for (_, sym, r) in rects() { Symbols.draw(sym, 14, color: Theme.textMuted, in: r) }
        Theme.border.setFill()
        NSRect(x: 5 * 30 + 3, y: 10, width: 1, height: 16).fill()
        if hasText {
            Theme.success.setFill()
            NSBezierPath(roundedRect: sendRect, xRadius: 6, yRadius: 6).fill()
            Symbols.draw("paperplane.fill", 14, color: .white, in: sendRect)
        } else {
            Symbols.draw("paperplane.fill", 14, color: Theme.textFaint, in: sendRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !readOnly else { return }
        let p = convert(event.locationInWindow, from: nil)
        if sendRect.contains(p) { onAction?(.send); return }
        if let hit = rects().first(where: { $0.2.contains(p) }) { onAction?(hit.0) }
    }
}
