import Foundation

/// The shortcodes people actually type. Unknown ones stay as :code:.
enum Emoji {
    static let table: [String: String] = [
        "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎", "heart": "❤️", "smile": "😄", "slightly_smiling_face": "🙂",
        "joy": "😂", "laughing": "😆", "wink": "😉", "tada": "🎉", "fire": "🔥", "eyes": "👀", "pray": "🙏", "clap": "👏",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "x": "❌", "warning": "⚠️", "rocket": "🚀", "100": "💯",
        "thinking_face": "🤔", "raised_hands": "🙌", "ok_hand": "👌", "wave": "👋", "sweat_smile": "😅", "sob": "😭",
        "coffee": "☕", "bug": "🐛", "memo": "📝", "point_up": "☝️", "point_right": "👉", "muscle": "💪", "sparkles": "✨",
        "cat": "🐱", "star": "⭐", "zap": "⚡", "bulb": "💡", "calendar": "📅", "link": "🔗", "lock": "🔒", "hourglass": "⌛",
    ]

    static func glyph(_ name: String) -> String {
        let base = name.split(separator: ":").first.map(String.init) ?? name
        return table[base] ?? ":\(name):"
    }

    static func replace(_ s: String) -> String {
        guard s.contains(":") else { return s }
        var out = ""
        var rest = Substring(s)
        while let a = rest.firstIndex(of: ":") {
            out += rest[..<a]
            let after = rest[rest.index(after: a)...]
            if let b = after.firstIndex(of: ":"), let g = table[String(after[..<b])] {
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
