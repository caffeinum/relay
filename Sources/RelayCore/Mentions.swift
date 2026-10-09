import Foundation

/// here | channel | everyone for `special`.
public enum MentionTarget: Hashable, Codable { case user(String), group(String), channel(String), special(String) }

/// `range` is in the display text, UTF-16.
public struct MentionToken: Equatable {
    public var range: NSRange; public var target: MentionTarget; public var label: String
    public init(range: NSRange, target: MentionTarget, label: String) { self.range = range; self.target = target; self.label = label }
}

/// Between what the composer shows (`@Mira Chen` as one atomic token) and
/// what Slack stores (`<@U123>`).
public enum Mentions {
    /// Display text + tokens → mrkdwn: & < > escaped outside tokens, tokens
    /// as <@U>, <!subteam^S>, <#C>, <!here>. Text typed as a plain `@foo`
    /// stays plain, since Slack resolves nothing in that case.
    public static func encode(_ display: String, tokens: [MentionToken]) -> String {
        let ns = display as NSString
        var out = ""
        var pos = 0
        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            guard t.range.location >= pos, NSMaxRange(t.range) <= ns.length else {
                log("mentions: token \(t.label) at \(t.range) overlaps or runs past the text; kept as text")
                continue
            }
            out += escape(ns.substring(with: NSRange(location: pos, length: t.range.location - pos)))
            out += wire(t.target)
            pos = NSMaxRange(t.range)
        }
        out += escape(ns.substring(from: pos))
        return out
    }

    /// mrkdwn → display text + tokens, for editing in place and restoring
    /// drafts. `label` gives a name without its sigil (`Mira Chen`, `eng`,
    /// `general`); nil falls back to the label inside the token, then the
    /// raw id. Links show as their url (or their label when it is the url
    /// without its scheme), since the composer has no link tokens.
    public static func decode(_ mrkdwn: String, label: (MentionTarget) -> String?) -> (text: String, tokens: [MentionToken]) {
        var text = ""
        var length = 0
        var tokens: [MentionToken] = []
        func append(_ s: String) { text += s; length += s.utf16.count }
        var rest = Substring(mrkdwn)
        while let open = rest.firstIndex(of: "<") {
            append(unescape(rest[..<open]))
            guard let close = rest[open...].firstIndex(of: ">") else { rest = rest[open...]; break }
            let inner = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let head = String(parts[0])
            let inline = parts.count > 1 ? unescape(parts[1]) : nil
            guard let (target, sigil, fallback) = parse(head) else {
                append(linkText(head: unescape(Substring(head)), label: inline))
                continue
            }
            let name = label(target) ?? inline.map { $0.hasPrefix(sigil) ? String($0.dropFirst()) : $0 } ?? fallback
            let shown = sigil + name
            tokens.append(MentionToken(range: NSRange(location: length, length: shown.utf16.count), target: target, label: shown))
            append(shown)
        }
        append(unescape(rest))
        return (text, tokens)
    }

    private static func parse(_ head: String) -> (MentionTarget, sigil: String, fallback: String)? {
        if head.hasPrefix("@") { let id = String(head.dropFirst()); return (.user(id), "@", id) }
        if head.hasPrefix("#") { let id = String(head.dropFirst()); return (.channel(id), "#", id) }
        if head.hasPrefix("!subteam^") { let id = String(head.dropFirst(9)); return (.group(id), "@", id) }
        for s in ["here", "channel", "everyone"] where head == "!\(s)" { return (.special(s), "@", s) }
        return nil
    }

    private static func linkText(head: String, label: String?) -> String {
        guard let label, label != head else { return head }
        if let colon = head.firstIndex(of: ":") {
            var bare = head[head.index(after: colon)...]
            while bare.hasPrefix("/") { bare = bare.dropFirst() }
            if bare == label { return label }
        }
        return head
    }

    private static func wire(_ t: MentionTarget) -> String {
        switch t {
        case .user(let id): return "<@\(id)>"
        case .group(let id): return "<!subteam^\(id)>"
        case .channel(let id): return "<#\(id)>"
        case .special(let s): return "<!\(s)>"
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func unescape(_ s: Substring) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
