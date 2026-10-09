import Testing
@testable import ChatCore

@Test func mentionsLinksAndEscapes() {
    let names = ["U1": "mira"]
    let s = "hi <@U1>, see <https://x.com/a?b=1&amp;c=2|the doc> in <#C9|eng> &lt;3 <!here>"
    #expect(Mrkdwn.plain(s, names: { names[$0] ?? $0 }) == "hi @mira, see the doc in #eng <3 @here")
    #expect(Mrkdwn.runs("<https://a.b>", names: { $0 }) == [.link(label: "https://a.b", url: "https://a.b")])
}
