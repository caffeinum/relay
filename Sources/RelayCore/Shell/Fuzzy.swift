import Foundation

/// One in-memory scorer for ⌘K, the sidebar filter and autocomplete. The
/// haystack is lowercased once; a keystroke only scans bytes. Every query
/// word has to match. A word scores, best first: a prefix of the whole
/// string, a prefix of a word inside it, a substring, then a subsequence
/// (more word starts hit, fewer gaps, the better). Shorter strings win ties.
public struct Fuzzy {
    private let hay: [[UInt8]]

    public init(_ haystack: [String]) { hay = haystack.map { Array($0.lowercased().utf8) } }

    public var count: Int { hay.count }

    /// (index, score), best first; ties keep haystack order. An empty query matches nothing.
    public func rank(_ q: String, limit: Int) -> [(Int, Int)] {
        let words = q.lowercased().split(separator: " ").map { Array($0.utf8) }
        guard !words.isEmpty else { return [] }
        var out: [(Int, Int)] = []
        for (i, h) in hay.enumerated() {
            var total = 0
            for w in words {
                let s = Self.score(w, h)
                if s == 0 { total = 0; break }
                total += s
            }
            if total > 0 { out.append((i, total)) }
        }
        out.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return Array(out.prefix(limit))
    }

    static func boundary(_ c: UInt8) -> Bool {
        !((c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c >= 128)
    }

    public static func score(_ w: [UInt8], _ h: [UInt8]) -> Int {
        guard !w.isEmpty, w.count <= h.count else { return 0 }
        let short = max(0, 64 - h.count)
        var best = 0
        let first = w[0]
        var i = 0
        let last = h.count - w.count
        while i <= last {
            if h[i] == first {
                var j = 1
                while j < w.count && h[i + j] == w[j] { j += 1 }
                if j == w.count {
                    let s = i == 0 ? 1000 : (boundary(h[i - 1]) ? 800 : 400)
                    if s > best { best = s }
                    if s == 1000 { break }
                }
            }
            i += 1
        }
        if best > 0 { return best + short }
        if w.count >= 3 { return initials(w, h).map { max(1, 100 + 20 * $0.hits - 5 * $0.gaps + short / 4) } ?? 0 }
        var hits = 0, gaps = 0, k = 0, prev = -1
        for (p, c) in h.enumerated() where k < w.count && c == w[k] {
            if p == 0 || boundary(h[p - 1]) { hits += 1 }
            if prev >= 0 && p != prev + 1 { gaps += 1 }
            prev = p
            k += 1
        }
        guard k == w.count else { return 0 }
        return max(1, 100 + 20 * hits - 5 * gaps + short / 4)
    }

    /// From three characters on, a scattered match only counts when each
    /// piece starts a word: "mcr" finds "mark channel read", "des" doesn't
    /// find "delete message".
    static func initials(_ w: [UInt8], _ h: [UInt8]) -> (hits: Int, gaps: Int)? {
        var k = 0, p = 0, hits = 0, gaps = 0
        while k < w.count {
            if k > 0, p < h.count, h[p] == w[k] { p += 1; k += 1; continue }
            var q = p
            while q < h.count, !(h[q] == w[k] && (q == 0 || boundary(h[q - 1]))) { q += 1 }
            guard q < h.count else { return nil }
            if k > 0 { gaps += 1 }
            hits += 1
            p = q + 1
            k += 1
        }
        return (hits, gaps)
    }
}
