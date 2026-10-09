import AppKit

/// design.md §1: color tokens that follow the appearance on their own, the
/// only type styles, radii, the floating shadow, and cached SF Symbols.
enum Theme {
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    private static func token(_ name: String, _ dark: NSColor, _ light: NSColor) -> NSColor {
        NSColor(name: name) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static let bg = token("bg", hex(0x1A1D21), hex(0xFFFFFF))
    static let bgHover = token("bgHover", hex(0x222529), hex(0xF8F8F8))
    static let bgRaised = token("bgRaised", hex(0x222529), hex(0xFFFFFF))
    static let border = token("border", hex(0x35373B), hex(0xDDDDDD))
    static let borderStrong = token("borderStrong", hex(0x565856), hex(0x868686))
    static let text = token("text", hex(0xD1D2D3), hex(0x1D1C1D))
    static let textStrong = token("textStrong", hex(0xF8F8F8), hex(0x1D1C1D))
    static let textMuted = token("textMuted", hex(0xABABAD), hex(0x616061))
    static let textFaint = token("textFaint", hex(0x7C7E80), hex(0x9A9A9A))
    static let link = token("link", hex(0x1D9BD1), hex(0x1264A3))
    static let linkChipBg = token("linkChipBg", hex(0x1D9BD1, 0.12), hex(0x1264A3, 0.08))
    static let mentionBg = token("mentionBg", hex(0x1D9BD1, 0.18), hex(0x1D9BD1, 0.10))
    static let mentionFg = token("mentionFg", hex(0x5DBDEB), hex(0x1264A3))
    static let mentionMeBg = token("mentionMeBg", hex(0xECB22E, 0.22), hex(0xF2C744, 0.30))
    static let mentionMeFg = token("mentionMeFg", hex(0xF2C744), hex(0x1D1C1D))
    static let mentionMeRow = token("mentionMeRow", hex(0xECB22E, 0.06), hex(0xFEF7E0))
    static let mentionMeBar = hex(0xECB22E)
    static let editingRow = hex(0xECB22E, 0.08)
    static let codeBg = token("codeBg", hex(0x2C2D30), hex(0xF6F6F6))
    static let codeBorder = token("codeBorder", hex(0x3B3D41), hex(0xDDDDDD))
    static let codeInline = token("codeInline", hex(0xE8912D), hex(0xC01343))
    static let quoteBar = token("quoteBar", hex(0x5E6064), hex(0xDDDDDD))
    static let unreadRed = hex(0xE01E5A)
    static let reactBg = token("reactBg", hex(0x2C2D30), hex(0xF2F2F2))
    static let reactMineBg = token("reactMineBg", hex(0x18435A), hex(0xE8F5FA))
    static let reactMineBorder = hex(0x1D9BD1)
    static let reactMineCount = token("reactMineCount", hex(0x1D9BD1), hex(0x1264A3))
    static let cursor = token("cursor", hex(0x1D9BD1), hex(0x1264A3))
    static let cursorTint = token("cursorTint", hex(0x1D9BD1, 0.10), hex(0x1264A3, 0.07))
    static let cursorTintDim = token("cursorTintDim", hex(0x1D9BD1, 0.04), hex(0x1264A3, 0.04))
    static let accentPill = token("accentPill", hex(0xBE79EC), hex(0x7C3AED))
    static let success = token("success", hex(0x2BAC76), hex(0x007A5A))

    // MARK: type (§1.2)

    enum Font {
        static let title = NSFont.systemFont(ofSize: 17, weight: .bold)
        static let name = NSFont.systemFont(ofSize: 14, weight: .semibold)
        static let body = NSFont.systemFont(ofSize: 14)
        static let bodyMedium = NSFont.systemFont(ofSize: 14, weight: .medium)
        static let bodyBold = NSFont.systemFont(ofSize: 14, weight: .semibold)
        static let bodyItalic = italic(body)
        static let bodyBoldItalic = italic(bodyBold)
        static let jumbo = NSFont.systemFont(ofSize: 28)
        static let meta = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        static let hoverTime = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        static let small = NSFont.systemFont(ofSize: 12)
        static let smallSemibold = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        static let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        static let badge = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        static let tag = NSFont.systemFont(ofSize: 9, weight: .bold)
        static let dividerLabel = NSFont.systemFont(ofSize: 11, weight: .bold)
        static let dayPill = NSFont.systemFont(ofSize: 12, weight: .semibold)
        static let emoji = NSFont.systemFont(ofSize: 15)

        static func italic(_ f: NSFont) -> NSFont {
            NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.italic), size: f.pointSize) ?? f
        }
    }

    enum Radius {
        static let row: CGFloat = 6, card: CGFloat = 8, palette: CGFloat = 12, avatar: CGFloat = 6
    }

    /// The floating shadow (§1.3), with an explicit path so no offscreen pass runs.
    static func floatShadow(_ layer: CALayer, radius corner: CGFloat, dark: Bool) {
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = dark ? 0.25 : 0.12
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    static func isDark(_ v: NSView) -> Bool { v.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Shapes on the first-frame path, drawn as paths: loading the SF Symbols
/// catalog costs ~100 ms the first time, so symbols wait for `Symbols.warm()`.
enum Glyphs {
    /// A chain link, 12×12, in `color`.
    static func link(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            let t = NSAffineTransform()
            t.translateX(by: 6, yBy: 6)
            t.rotate(byDegrees: -45)
            t.concat()
            color.setStroke()
            for dx in [-3.0, 3.0] {
                let p = NSBezierPath(roundedRect: NSRect(x: dx - 3.5, y: -2.25, width: 7, height: 4.5), xRadius: 2.25, yRadius: 2.25)
                p.lineWidth = 1.4
                p.stroke()
            }
            return true
        }
    }

    static func chevronDown(in r: NSRect, _ color: NSColor, flipped: Bool = true) {
        let p = NSBezierPath()
        let w: CGFloat = 7, h: CGFloat = 3.5
        let top = flipped ? r.midY - h / 2 : r.midY + h / 2
        let bottom = flipped ? r.midY + h / 2 : r.midY - h / 2
        p.move(to: NSPoint(x: r.midX - w / 2, y: top))
        p.line(to: NSPoint(x: r.midX, y: bottom))
        p.line(to: NSPoint(x: r.midX + w / 2, y: top))
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        color.setStroke()
        p.stroke()
    }
}

enum Symbols {
    /// Loads the symbol catalog off main, after the first frame.
    static func warm() {
        DispatchQueue.global(qos: .utility).async { _ = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil) }
    }

    private struct Key: Hashable { let name: String; let size: CGFloat; let weight: NSFont.Weight.RawValue }
    private static var cache: [Key: NSImage] = [:]

    /// A template SF Symbol; a missing name is logged once and drawn as a
    /// question mark so the gap is visible.
    static func image(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSImage {
        let k = Key(name: name, size: size, weight: weight.rawValue)
        if let i = cache[k] { return i }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let img: NSImage
        if let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            img = i
        } else {
            log("symbol \(name) is missing on this system")
            img = NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
        }
        img.isTemplate = true
        cache[k] = img
        return img
    }

    /// The symbol filled with `color`, for drawing straight into a context.
    static func draw(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, color: NSColor, in rect: NSRect) {
        let img = image(name, size, weight)
        let s = img.size
        let r = NSRect(x: (rect.midX - s.width / 2).rounded(), y: (rect.midY - s.height / 2).rounded(), width: s.width, height: s.height)
        tinted(img, color).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }
}

import RelayCore
