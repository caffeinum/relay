import Foundation
import Testing
@testable import RelayCore

private let names: (MentionTarget) -> String? = { t in
    switch t {
    case .user("U1"): return "Mira Chen"
    case .group("S1"): return "eng"
    case .channel("C1"): return "general"
    case .special(let s): return s
    default: return nil
    }
}

private func token(_ display: String, _ label: String, _ target: MentionTarget) -> MentionToken {
    MentionToken(range: (display as NSString).range(of: label), target: target, label: label)
}

@Test func encodesTokensAndEscapesText() {
    let text = "hi @Mira Chen & @eng, see #general <now> @here"
    let tokens = [token(text, "@Mira Chen", .user("U1")), token(text, "@eng", .group("S1")),
                  token(text, "#general", .channel("C1")), token(text, "@here", .special("here"))]
    #expect(Mentions.encode(text, tokens: tokens) == "hi <@U1> &amp; <!subteam^S1>, see <#C1> &lt;now&gt; <!here>")
}

@Test func plainAtTextPassesThrough() {
    #expect(Mentions.encode("ping @foo", tokens: []) == "ping @foo")
    let d = Mentions.decode("ping @foo", label: names)
    #expect(d.text == "ping @foo" && d.tokens.isEmpty)
}

@Test func decodeThenEncodeKeepsIDs() {
    let wire = "<@U1> and <@U9|zed> in <#C1|general> cc <!subteam^S1|@eng> <!channel> a &amp; b &lt;3"
    let d = Mentions.decode(wire, label: names)
    #expect(d.text == "@Mira Chen and @zed in #general cc @eng @channel a & b <3")
    #expect(d.tokens.map(\.target) == [.user("U1"), .user("U9"), .channel("C1"), .group("S1"), .special("channel")])
    #expect(Mentions.encode(d.text, tokens: d.tokens) == "<@U1> and <@U9> in <#C1> cc <!subteam^S1> <!channel> a &amp; b &lt;3")
}

@Test func unknownIDsKeepTheRawID() {
    let d = Mentions.decode("hey <@U404>", label: { _ in nil })
    #expect(d.text == "hey @U404")
    #expect(d.tokens == [MentionToken(range: NSRange(location: 4, length: 5), target: .user("U404"), label: "@U404")])
}

@Test func roundTripsDisplayText() {
    let cases: [(String, [(String, MentionTarget)])] = [
        ("plain & <odd> text", []),
        ("🙂 @Mira Chen says hi", [("@Mira Chen", .user("U1"))]),
        ("@eng @here #general", [("@eng", .group("S1")), ("@here", .special("here")), ("#general", .channel("C1"))]),
        ("unclosed < and > & ;", []),
    ]
    for (text, ts) in cases {
        let tokens = ts.map { token(text, $0.0, $0.1) }
        let d = Mentions.decode(Mentions.encode(text, tokens: tokens), label: names)
        #expect(d.text == text)
        #expect(d.tokens == tokens)
    }
}

@Test func linksDecodeToTheirURL() {
    #expect(Mentions.decode("<https://x.dev/a?b=1&amp;c=2>", label: names).text == "https://x.dev/a?b=1&c=2")
    #expect(Mentions.decode("<mailto:a@b.co|a@b.co>", label: names).text == "a@b.co")
    #expect(Mentions.decode("<https://x.dev|the docs>", label: names).text == "https://x.dev")
    #expect(Mentions.decode("broken <tag", label: names).text == "broken <tag")
}
