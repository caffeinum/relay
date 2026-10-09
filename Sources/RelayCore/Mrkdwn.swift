import Foundation

/// Slack's message text: blocks (paragraphs, `>` quotes, ``` code, lists)
/// holding inline runs (`*bold*`, `_italic_`, `~strike~`, `` `code` ``,
/// `<@U1>`, `<#C1|name>`, `<!here>`, `<url|label>`, `:emoji:`), with
/// &amp; &lt; &gt; unescaped exactly once. One left-to-right pass.
public enum Mrkdwn {
    public enum MentionRef: Equatable {
        case user(String, label: String?), channel(String, label: String?), group(String, label: String?), special(String)
    }

    public indirect enum Inline: Equatable {
        case text(String), bold([Inline]), italic([Inline]), strike([Inline]), code(String)
        case mention(MentionRef), link(label: String?, url: String), emoji(String)
    }

    public enum Block: Equatable {
        case paragraph([Inline]), quote([Block]), code(String), list(ordered: Bool, items: [[Inline]])
    }

    public static func parse(_ s: String) -> [Block] {
        let u = Array(s.unicodeScalars)
        var out: [Block] = []
        var i = 0
        var textStart = 0
        while i + 2 < u.count {
            if u[i] == "`", u[i + 1] == "`", u[i + 2] == "`", let close = fence(u, from: i + 3) {
                lines(u, textStart, i, into: &out)
                var lo = i + 3, hi = close
                if lo < hi, u[lo] == "\n" { lo += 1 }
                if lo < hi, u[hi - 1] == "\n" { hi -= 1 }
                out.append(.code(unescape(u, lo, hi)))
                i = close + 3
                textStart = i
            } else {
                i += 1
            }
        }
        lines(u, textStart, u.count, into: &out)
        return out
    }

    private static func fence(_ u: [Unicode.Scalar], from: Int) -> Int? {
        var j = from
        while j + 2 < u.count {
            if u[j] == "`", u[j + 1] == "`", u[j + 2] == "`" { return j }
            j += 1
        }
        return nil
    }

    // MARK: blocks

    private enum LineKind: Equatable { case plain, quote(Int), bullet(Int), number(Int), quoteAll(Int) }

    private static func kind(_ u: [Unicode.Scalar], _ lo: Int, _ hi: Int) -> LineKind {
        if has(u, lo, hi, gt3) { return .quoteAll(skipSpace(u, lo + 12, hi)) }
        if has(u, lo, hi, gt) { return .quote(skipSpace(u, lo + 4, hi, max: 1)) }
        if has(u, lo, hi, plainGT) { return .quote(skipSpace(u, lo + 1, hi, max: 1)) }
        if lo + 1 < hi, u[lo] == "•" || u[lo] == "◦", u[lo + 1] == " " { return .bullet(lo + 2) }
        var j = lo
        while j < hi, j - lo < 4, ("0"..."9").contains(u[j]) { j += 1 }
        if j > lo, j + 1 < hi, u[j] == "." || u[j] == ")", u[j + 1] == " " { return .number(j + 2) }
        return .plain
    }

    private static func lines(_ u: [Unicode.Scalar], _ lo: Int, _ hi: Int, into out: inout [Block]) {
        guard lo < hi else { return }
        var para: [Inline] = []
        var paraEmpty = true
        var quote: [Int] = []          // flattened (start, end) pairs of quoted line content
        var list: (ordered: Bool, items: [[Inline]])?

        func flushPara() {
            while case .text(let t)? = para.last, t.allSatisfy({ $0 == "\n" }) { para.removeLast() }
            if !para.isEmpty { out.append(.paragraph(merge(para))) }
            para = []
            paraEmpty = true
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            var inner: [Block] = []
            var k = 0
            var run: [Unicode.Scalar] = []
            while k < quote.count {
                if k > 0 { run.append("\n") }
                run.append(contentsOf: u[quote[k]..<quote[k + 1]])
                k += 2
            }
            lines(run, 0, run.count, into: &inner)
            out.append(.quote(inner))
            quote = []
        }
        func flushList() {
            if let l = list { out.append(.list(ordered: l.ordered, items: l.items)) }
            list = nil
        }

        var start = lo
        while true {
            var end = start
            while end < hi, u[end] != "\n" { end += 1 }
            let k = kind(u, start, end)
            switch k {
            case .quoteAll(let c):
                flushPara(); flushList()
                quote.append(contentsOf: [c, hi])
                flushQuote()
                return
            case .quote(let c):
                flushPara(); flushList()
                quote.append(contentsOf: [c, end])
            case .bullet(let c), .number(let c):
                flushPara(); flushQuote()
                let ordered: Bool
                if case .number = k { ordered = true } else { ordered = false }
                if list?.ordered != ordered { flushList(); list = (ordered, []) }
                list?.items.append(merge(inlines(u, c, end)))
            case .plain:
                flushQuote(); flushList()
                if paraEmpty, start == end { break }
                if !paraEmpty { para.append(.text("\n")) }
                para.append(contentsOf: inlines(u, start, end))
                paraEmpty = false
            }
            if end >= hi { break }
            start = end + 1
        }
        flushPara(); flushQuote(); flushList()
    }

    // MARK: inline

    private static func inlines(_ u: [Unicode.Scalar], _ lo: Int, _ hi: Int, inside: Unicode.Scalar? = nil) -> [Inline] {
        var out: [Inline] = []
        var text = lo
        var i = lo
        var noClose: Set<Unicode.Scalar> = []
        func flush(_ to: Int) { if to > text { out.append(.text(unescape(u, text, to))) } }
        while i < hi {
            let c = u[i]
            switch c {
            case "<":
                if !noClose.contains("<"), let j = find(u, ">", i + 1, hi, stopAt: "<") {
                    flush(i)
                    out.append(token(u, i + 1, j))
                    i = j + 1
                    text = i
                    continue
                }
                noClose.insert("<")
            case "`":
                if !noClose.contains("`"), let j = find(u, "`", i + 1, hi, stopAt: nil), j > i + 1 {
                    flush(i)
                    out.append(.code(unescape(u, i + 1, j)))
                    i = j + 1
                    text = i
                    continue
                }
                noClose.insert("`")
            case "*", "_", "~":
                if c != inside, !noClose.contains(c), opens(u, i, lo, hi) {
                    if let j = closer(u, c, i + 1, hi) {
                        flush(i)
                        let inner = merge(inlines(u, i + 1, j, inside: c))
                        out.append(c == "*" ? .bold(inner) : c == "_" ? .italic(inner) : .strike(inner))
                        i = j + 1
                        text = i
                        continue
                    }
                    noClose.insert(c)
                }
            case ":":
                if let (name, j) = emoji(u, i + 1, hi) {
                    flush(i)
                    out.append(.emoji(name))
                    i = j + 1
                    text = i
                    continue
                }
            default: break
            }
            i += 1
        }
        flush(hi)
        return out
    }

    private static func isWord(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        if v < 0x80 { return (v >= 0x30 && v <= 0x39) || (v | 0x20 >= 0x61 && v | 0x20 <= 0x7A) }
        return c.properties.isAlphabetic
    }
    private static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\u{A0}" }

    private static func opens(_ u: [Unicode.Scalar], _ i: Int, _ lo: Int, _ hi: Int) -> Bool {
        guard i + 1 < hi, !isSpace(u[i + 1]), u[i + 1] != u[i] else { return false }
        return i == lo || !isWord(u[i - 1])
    }

    /// The closing marker: not after a space, not before a word character.
    /// `<…>` tokens and `code` spans are stepped over whole.
    private static func closer(_ u: [Unicode.Scalar], _ c: Unicode.Scalar, _ from: Int, _ hi: Int) -> Int? {
        var j = from + 1
        var tickOpen = true
        while j < hi {
            let x = u[j]
            if x == "<", let k = find(u, ">", j + 1, hi, stopAt: "<") { j = k + 1; continue }
            if x == "`", tickOpen {
                if let k = find(u, "`", j + 1, hi, stopAt: nil) { j = k + 1; continue }
                tickOpen = false
            }
            if x == c, !isSpace(u[j - 1]), j + 1 == hi || !isWord(u[j + 1]) { return j }
            j += 1
        }
        return nil
    }

    private static func find(_ u: [Unicode.Scalar], _ c: Unicode.Scalar, _ from: Int, _ hi: Int, stopAt: Unicode.Scalar?) -> Int? {
        var j = from
        while j < hi {
            if u[j] == c { return j }
            if u[j] == "\n" || u[j] == stopAt { return nil }
            j += 1
        }
        return nil
    }

    private static func isEmojiChar(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "_" || c == "+" || c == "-" || c == "'"
    }

    /// `:name:` or `:name::skin-tone-2:` starting after the first colon.
    private static func emoji(_ u: [Unicode.Scalar], _ from: Int, _ hi: Int) -> (String, Int)? {
        func name(_ s: Int) -> Int? {
            var j = s
            while j < hi, j - s <= 64, isEmojiChar(u[j]) { j += 1 }
            return j > s && j < hi && u[j] == ":" ? j : nil
        }
        guard let end = name(from) else { return nil }
        var s = String(String.UnicodeScalarView(u[from..<end]))
        var last = end
        if end + 1 < hi, u[end + 1] == ":", let tone = name(end + 2) {
            let t = String(String.UnicodeScalarView(u[(end + 2)..<tone]))
            if t.hasPrefix("skin-tone-") { s += "::" + t; last = tone }
        }
        return (s, last)
    }

    private static func token(_ u: [Unicode.Scalar], _ lo: Int, _ hi: Int) -> Inline {
        var bar = lo
        while bar < hi, u[bar] != "|" { bar += 1 }
        let head = String(String.UnicodeScalarView(u[lo..<bar]))
        let label = bar < hi ? unescape(u, bar + 1, hi) : nil
        if head.hasPrefix("@") { return .mention(.user(String(head.dropFirst()), label: label)) }
        if head.hasPrefix("#") { return .mention(.channel(String(head.dropFirst()), label: label)) }
        if head.hasPrefix("!") {
            let cmd = head.dropFirst()
            if cmd.hasPrefix("subteam^") { return .mention(.group(String(cmd.dropFirst(8)), label: label)) }
            if cmd.hasPrefix("date^") { return .text(label ?? String(cmd)) }
            return .mention(.special(cmd.split(separator: "^").first.map(String.init) ?? String(cmd)))
        }
        let url = unescape(u, lo, bar)
        return .link(label: label, url: url)
    }

    private static let gt3 = Array("&gt;&gt;&gt;".unicodeScalars), gt = Array("&gt;".unicodeScalars), lt = Array("&lt;".unicodeScalars)
    private static let amp = Array("&amp;".unicodeScalars), plainGT: [Unicode.Scalar] = [">"]

    private static func has(_ u: [Unicode.Scalar], _ lo: Int, _ hi: Int, _ p: [Unicode.Scalar]) -> Bool {
        guard hi - lo >= p.count else { return false }
        for k in 0..<p.count where u[lo + k] != p[k] { return false }
        return true
    }

    private static func skipSpace(_ u: [Unicode.Scalar], _ i: Int, _ hi: Int, max: Int = .max) -> Int {
        var j = i
        while j < hi, j - i < max, u[j] == " " { j += 1 }
        return j
    }

    static func unescape(_ u: [Unicode.Scalar], _ lo: Int, _ hi: Int) -> String {
        var out = String.UnicodeScalarView()
        var i = lo
        while i < hi {
            if u[i] == "&" {
                if has(u, i, hi, amp) { out.append("&"); i += 5; continue }
                if has(u, i, hi, lt) { out.append("<"); i += 4; continue }
                if has(u, i, hi, gt) { out.append(">"); i += 4; continue }
            }
            out.append(u[i])
            i += 1
        }
        return String(out)
    }

    private static func merge(_ xs: [Inline]) -> [Inline] {
        var out: [Inline] = []
        out.reserveCapacity(xs.count)
        for x in xs {
            if case .text(let b) = x, case .text(let a)? = out.last { out[out.count - 1] = .text(a + b) } else { out.append(x) }
        }
        return out
    }

    // MARK: derived

    public static func links(_ s: String) -> [(label: String?, url: String)] {
        var out: [(label: String?, url: String)] = []
        func walk(_ xs: [Inline]) {
            for x in xs {
                switch x {
                case .link(let l, let u): out.append((l, u))
                case .bold(let c), .italic(let c), .strike(let c): walk(c)
                default: break
                }
            }
        }
        func blocks(_ bs: [Block]) {
            for b in bs {
                switch b {
                case .paragraph(let xs): walk(xs)
                case .quote(let inner): blocks(inner)
                case .list(_, let items): items.forEach(walk)
                case .code: break
                }
            }
        }
        blocks(parse(s))
        return out
    }

    /// Text for search: markers dropped, mentions as @name, links as their label.
    public static func plain(_ s: String, names: (String) -> String) -> String {
        func inl(_ xs: [Inline]) -> String {
            xs.map { x -> String in
                switch x {
                case .text(let t), .code(let t): return t
                case .bold(let c), .italic(let c), .strike(let c): return inl(c)
                case .emoji(let n): return ":\(n):"
                case .link(let l, let u): return l ?? u.replacingOccurrences(of: "mailto:", with: "")
                case .mention(.user(let id, let l)): return "@" + (l ?? names(id))
                case .mention(.channel(let id, let l)): return "#" + (l ?? id)
                case .mention(.group(_, let l)): return l ?? "@group"
                case .mention(.special(let n)): return "@" + n
                }
            }.joined()
        }
        func blk(_ bs: [Block]) -> String {
            bs.map { b -> String in
                switch b {
                case .paragraph(let xs): return inl(xs)
                case .quote(let inner): return blk(inner)
                case .code(let t): return t
                case .list(_, let items): return items.map(inl).joined(separator: "\n")
                }
            }.joined(separator: "\n")
        }
        return blk(parse(s))
    }
}
