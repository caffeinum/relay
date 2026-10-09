import AppKit
import RelayCore

/// Edit in place (§8): one reusable editor laid over the row's body. ↩
/// saves, ⇧↩ adds a line, esc cancels. The row's height follows the editor.
final class InlineEditor: NSView, NSTextViewDelegate {
    private let box = NSView()
    private let scroll = NSScrollView()
    private(set) var textView: NSTextView
    private let hint = NSTextField(labelWithString: "escape to cancel • enter to save")
    private let cancel = SmallButton(title: "Cancel", primary: false)
    private let save = SmallButton(title: "Save", primary: true)
    private(set) var message: Message?
    var onSave: ((Message, String) -> Void)?
    var onCancel: (() -> Void)?
    var onHeight: (() -> Void)?

    static let footer: CGFloat = 40, minBox: CGFloat = 42

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        addSubview(box)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        box.addSubview(scroll)
        textView.delegate = self
        guard !(textView is ComposerTextView) else { configureRest(); return }
        textView.font = Theme.Font.body
        textView.textColor = Theme.text
        textView.insertionPointColor = Theme.textStrong
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        configureRest()
    }

    private func configureRest() {
        hint.font = Theme.Font.small
        hint.textColor = Theme.textMuted
        addSubview(hint)
        addSubview(cancel)
        addSubview(save)
        cancel.onClick = { [weak self] in self?.onCancel?() }
        save.onClick = { [weak self] in self?.commit() }
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        box.layer?.backgroundColor = Theme.bg.cgColor
        box.layer?.borderColor = Theme.borderStrong.cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    func begin(_ m: Message, text: String, tokens: [MentionToken]) {
        message = m
        if let c = textView as? ComposerTextView { c.load(text, tokens: tokens) } else { textView.string = text }
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        isHidden = false
        needsDisplay = true
    }

    func end() {
        message = nil
        isHidden = true
        textView.string = ""
    }

    /// The editor's full height at a width: the box grows with the text up to 12 lines.
    func height(width: CGFloat) -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return Self.minBox + Self.footer }
        tc.size = NSSize(width: max(40, width - 24), height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let text = max(Body.lineHeight, ceil(lm.usedRect(for: tc).height))
        return max(Self.minBox, min(text, Body.lineHeight * 12) + 22) + Self.footer
    }

    override func layout() {
        super.layout()
        let b = bounds
        let boxH = b.height - Self.footer
        box.frame = NSRect(x: 0, y: 0, width: b.width, height: boxH)
        scroll.frame = NSRect(x: 12, y: 11, width: b.width - 24, height: boxH - 22)
        textView.frame.size.width = scroll.contentSize.width
        save.frame = NSRect(x: b.width - 60, y: boxH + 8, width: 60, height: 24)
        cancel.frame = NSRect(x: b.width - 128, y: boxH + 8, width: 64, height: 24)
        hint.sizeToFit()
        hint.setFrameOrigin(NSPoint(x: 0, y: boxH + 8 + (24 - hint.frame.height) / 2))
    }

    func focus() { window?.makeFirstResponder(textView) }

    private func commit() {
        guard let m = message else { return }
        let mrkdwn = (textView as? ComposerTextView)?.mrkdwn ?? Mentions.encode(textView.string, tokens: [])
        onSave?(m, mrkdwn.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func textDidChange(_ notification: Notification) { onHeight?() }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { textView.insertNewlineIgnoringFieldEditor(nil); return true }
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

final class SmallButton: NSView {
    private let title: String
    private let primary: Bool
    var onClick: (() -> Void)?

    init(title: String, primary: Bool) {
        self.title = title
        self.primary = primary
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if primary { Theme.success.setFill(); path.fill() } else { Theme.border.setStroke(); path.lineWidth = 1; path.stroke() }
        let a = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: primary ? NSColor.white : Theme.text])
        let s = a.size()
        a.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
