import Foundation
import RelayCore

/// Shortcodes for views outside the message list. Unknown ones stay as :code:.
enum Emoji {
    static func glyph(_ name: String) -> String { EmojiData.glyph(name) ?? ":\(name):" }

    static func replace(_ s: String) -> String {
        guard s.contains(":") else { return s }
        var out = ""
        var rest = Substring(s)
        while let a = rest.firstIndex(of: ":") {
            out += rest[..<a]
            let after = rest[rest.index(after: a)...]
            if let b = after.firstIndex(of: ":"), let g = EmojiData.glyph(String(after[..<b])) {
                out += g
                rest = after[after.index(after: b)...]
            } else {
                out += ":"
                rest = after
            }
        }
        return out + rest
    }
}
