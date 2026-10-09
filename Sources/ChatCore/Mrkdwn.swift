import Foundation

/// Slack's message text: `<@U1>`, `<#C1|name>`, `<!here>`, `<url|label>`,
/// with &amp; &lt; &gt; escaped. Turned into runs the UI can style, or
/// plain text for search.
public enum Mrkdwn {
    public enum Run: Equatable {
        case text(String)
        case mention(String)
        case channel(String)
        case link(label: String, url: String)
    }

    public static func runs(_ s: String, names: (String) -> String) -> [Run] {
        var out: [Run] = []
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "<") {
            if open > rest.startIndex { out.append(.text(unescape(rest[..<open]))) }
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let inner = String(rest[rest.index(after: open)..<close])
            out.append(token(inner, names: names))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { out.append(.text(unescape(rest))) }
        return out
    }

    private static func token(_ inner: String, names: (String) -> String) -> Run {
        let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
        let head = parts.first ?? ""
        let label = parts.count > 1 ? unescape(Substring(parts[1])) : nil
        if head.hasPrefix("@") { return .mention("@" + (label ?? names(String(head.dropFirst())))) }
        if head.hasPrefix("#") { return .channel("#" + (label ?? String(head.dropFirst()))) }
        if head.hasPrefix("!") {
            let cmd = head.dropFirst()
            if cmd.hasPrefix("subteam^") { return .mention(label ?? "@group") }
            return .mention(label ?? "@" + (cmd.split(separator: "^").first.map(String.init) ?? String(cmd)))
        }
        let url = unescape(Substring(head))
        return .link(label: label ?? url.replacingOccurrences(of: "mailto:", with: ""), url: url)
    }

    public static func plain(_ s: String, names: (String) -> String) -> String {
        runs(s, names: names).map {
            switch $0 {
            case .text(let t), .mention(let t), .channel(let t): return t
            case .link(let label, _): return label
            }
        }.joined()
    }

    static func unescape(_ s: Substring) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
