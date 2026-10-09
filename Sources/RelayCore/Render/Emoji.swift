import Foundation

/// Slack shortcode → unicode, with aliases and skin tones ("wave::skin-tone-3").
public enum EmojiData {
    public static let byName: [String: String] = {
        var d: [String: String] = [:]
        d.reserveCapacity(2000)
        for line in EmojiTable.pairs.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            d[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return d
    }()

    public static let names: [String] = byName.keys.sorted()
    static let toned: Set<String> = Set(EmojiTable.skinTones.split(separator: "\n").map(String.init))
    private static let tones = ["2": "\u{1F3FB}", "3": "\u{1F3FC}", "4": "\u{1F3FD}", "5": "\u{1F3FE}", "6": "\u{1F3FF}"]

    /// nil when the name isn't a standard emoji (it may be a custom one).
    public static func glyph(_ name: String) -> String? {
        let parts = name.components(separatedBy: "::")
        guard let base = byName[parts[0]] else { return nil }
        guard parts.count > 1, toned.contains(parts[0]), parts[1].hasPrefix("skin-tone-"),
              let mod = tones[String(parts[1].dropFirst(10))] else { return base }
        let scalars = Array(base.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.append(scalars[0])
        out.append(contentsOf: mod.unicodeScalars)
        out.append(contentsOf: scalars.dropFirst().filter { $0 != "\u{FE0F}" })
        return String(out)
    }
}

public enum EmojiSearch {
    /// Prefix matches before substring ones; within each, the most used
    /// first, then the shortest name. Custom emoji rank with the rest.
    public static func rank(_ q: String, frequent: [String: Int], custom: [String: String], limit: Int) -> [String] {
        let q = q.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        guard !q.isEmpty else {
            return frequent.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
        }
        var scored: [(name: String, score: Int)] = []
        func consider(_ n: String) {
            let s: Int
            if n == q { s = 0 } else if n.hasPrefix(q) { s = 1 }
            else if n.contains("_" + q) || n.contains("-" + q) { s = 2 }
            else if n.contains(q) { s = 3 } else { return }
            scored.append((n, s))
        }
        for n in EmojiData.names { consider(n) }
        for n in custom.keys where EmojiData.byName[n] == nil { consider(n) }
        scored.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            let fa = frequent[$0.name] ?? 0, fb = frequent[$1.name] ?? 0
            if fa != fb { return fa > fb }
            if $0.name.count != $1.name.count { return $0.name.count < $1.name.count }
            return $0.name < $1.name
        }
        return scored.prefix(limit).map(\.name)
    }
}
