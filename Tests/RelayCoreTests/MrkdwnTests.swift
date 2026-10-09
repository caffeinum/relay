import Foundation
import Testing
@testable import RelayCore

private typealias I = Mrkdwn.Inline
private func p(_ xs: I...) -> Mrkdwn.Block { .paragraph(xs) }

@Test func mentionsLinksAndEscapes() {
    let names = ["U1": "mira"]
    let s = "hi <@U1>, see <https://x.com/a?b=1&amp;c=2|the doc> in <#C9|eng> &lt;3 <!here>"
    #expect(Mrkdwn.plain(s, names: { names[$0] ?? $0 }) == "hi @mira, see the doc in #eng <3 @here")
    #expect(Mrkdwn.runs("<https://a.b>", names: { $0 }) == [.link(label: "https://a.b", url: "https://a.b")])
}

@Test func bold() { #expect(Mrkdwn.parse("a *b c* d") == [p(.text("a "), .bold([.text("b c")]), .text(" d"))]) }
@Test func italic() { #expect(Mrkdwn.parse("_hi_") == [p(.italic([.text("hi")]))]) }
@Test func strike() { #expect(Mrkdwn.parse("~old~ new") == [p(.strike([.text("old")]), .text(" new"))]) }
@Test func nested() { #expect(Mrkdwn.parse("*bold _both_*") == [p(.bold([.text("bold "), .italic([.text("both")])]))]) }
@Test func inlineCode() { #expect(Mrkdwn.parse("run `make *all*` now") == [p(.text("run "), .code("make *all*"), .text(" now"))]) }

@Test func codeBlock() {
    #expect(Mrkdwn.parse("before\n```\nlet x = *y*\n  <b>\n```\nafter") ==
            [p(.text("before")), .code("let x = *y*\n  <b>"), p(.text("after"))])
    #expect(Mrkdwn.parse("see ```a &lt; b``` ok") == [p(.text("see ")), .code("a < b"), p(.text(" ok"))])
}

@Test func quote() {
    #expect(Mrkdwn.parse("&gt; quoted *line*\n&gt; two\nplain") ==
            [.quote([p(.text("quoted "), .bold([.text("line")]), .text("\ntwo"))]), p(.text("plain"))])
    #expect(Mrkdwn.parse("&gt;&gt;&gt; all\nof it") == [.quote([p(.text("all\nof it"))])])
}

@Test func lists() {
    #expect(Mrkdwn.parse("• one\n• *two*\n1. a\n2. b") ==
            [.list(ordered: false, items: [[.text("one")], [.bold([.text("two")])]]), .list(ordered: true, items: [[.text("a")], [.text("b")]])])
}

@Test func mentions() {
    #expect(Mrkdwn.parse("<@U1> <@U2|tom> <#C1|eng> <!subteam^S1|@devs> <!here> <!channel>") == [p(
        .mention(.user("U1", label: nil)), .text(" "), .mention(.user("U2", label: "tom")), .text(" "),
        .mention(.channel("C1", label: "eng")), .text(" "), .mention(.group("S1", label: "@devs")), .text(" "),
        .mention(.special("here")), .text(" "), .mention(.special("channel")))])
}

@Test func links() {
    #expect(Mrkdwn.parse("<https://a.b/c|label> <https://x.y>") == [p(.link(label: "label", url: "https://a.b/c"), .text(" "), .link(label: nil, url: "https://x.y"))])
    #expect(Mrkdwn.links("*<https://a.b|x>* and <mailto:a@b.c>").map(\.url) == ["https://a.b", "mailto:a@b.c"])
}

@Test func emoji() {
    #expect(Mrkdwn.parse("ok :+1: :wave::skin-tone-3: at 10:30") == [p(.text("ok "), .emoji("+1"), .text(" "), .emoji("wave::skin-tone-3"), .text(" at 10:30"))])
    #expect(EmojiData.glyph("+1") == "👍")
    #expect(EmojiData.glyph("wave::skin-tone-3") == "👋🏼")
    #expect(EmojiData.glyph("thinking_face") == "🤔")
    #expect(EmojiData.glyph("not_a_real_emoji") == nil)
}

@Test func markersInsideWordsStayPlain() {
    #expect(Mrkdwn.parse("snake_case_name and 2*3*4") == [p(.text("snake_case_name and 2*3*4"))])
    #expect(Mrkdwn.parse("* not bold *") == [p(.text("* not bold *"))])
    #expect(Mrkdwn.parse("_<https://a.b/x_y|link>_") == [p(.italic([.link(label: "link", url: "https://a.b/x_y")]))])
}

@Test func entitiesUnescapedOnce() {
    #expect(Mrkdwn.parse("&amp;lt; &amp; &lt;b&gt;") == [p(.text("&lt; & <b>"))])
    #expect(Mrkdwn.parse("`&amp;amp;`") == [p(.code("&amp;"))])
}

@Test func unclosedMarkersAreText() {
    #expect(Mrkdwn.parse("*a *b *c") == [p(.text("*a *b *c"))])
    #expect(Mrkdwn.parse("<oops") == [p(.text("<oops"))])
    #expect(Mrkdwn.parse("```never closed") == [p(.text("```never closed"))])
}

@Test func blankLinesInsideParagraphKept() {
    #expect(Mrkdwn.parse("a\n\nb\n") == [p(.text("a\n\nb"))])
}

@Test func twentyKilobytesUnderFiveMs() {
    let chunk = "*bold* _it_ `code` <@U1> <https://a.b|l> :+1: snake_case &amp; ~s~ *open _x\n&gt; quote\n• item\n```\ncode\n```\n"
    let s = String(repeating: chunk, count: 20_000 / chunk.utf8.count + 1)
    #expect(!Mrkdwn.parse(s).isEmpty)
    let ms = fastest(10) { _ = Mrkdwn.parse(s) } * 1000
    #if DEBUG
    let budget = 25.0   // -Onone runs the scalar loop ~5x slower; the 5 ms target is for the shipped build
    #else
    let budget = 5.0
    #endif
    #expect(ms < budget, "parse took \(ms)ms")
}

/// Quadratic scanning would make 8x the input cost ~64x; linear stays near 8x.
@Test func pathologicalInputIsLinear() {
    let small = String(repeating: "*a _b ~c `d <e ", count: 500), big = String(repeating: "*a _b ~c `d <e ", count: 4000)
    let ratio = fastest(5) { _ = Mrkdwn.parse(big) } / fastest(5) { _ = Mrkdwn.parse(small) }
    #expect(ratio < 20, "8x input took \(ratio)x the time")
}

/// The best of n runs: wall-clock noise from a busy machine only ever adds time.
func fastest(_ n: Int, _ f: () -> Void) -> Double {
    (0..<n).map { _ in let t = Date(); f(); return Date().timeIntervalSince(t) }.min()!
}
