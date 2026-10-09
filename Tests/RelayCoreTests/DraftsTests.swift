import Foundation
import Testing
@testable import RelayCore

@Test func draftsSurviveReopeningTheStore() throws {
    let path = try tempPath()
    do {
        let s = try makeStore(path)
        try s.saveDraft(Draft(channel: "C1", threadTS: nil, text: "hello <@U2>", selection: NSRange(location: 5, length: 2),
                              updated: Date(timeIntervalSince1970: 10)))
        try s.saveDraft(Draft(channel: "C1", threadTS: "1.000000", text: "in thread", selection: NSRange(location: 9, length: 0),
                              updated: Date(timeIntervalSince1970: 20)))
    }
    let s = try makeStore(path)
    let d = try #require(try s.draft("C1", thread: nil))
    #expect(d.text == "hello <@U2>")
    #expect(d.selection == NSRange(location: 5, length: 2))
    #expect(d.updated == Date(timeIntervalSince1970: 10))
    #expect(try s.draft("C1", thread: "1.000000")?.text == "in thread")
    #expect(try s.drafts().map(\.threadTS) == ["1.000000", nil])
    #expect(try s.draftThreads("C1") == ["1.000000"])
}

@Test func emptyDraftDeletes() throws {
    let s = try makeStore()
    try s.saveDraft(Draft(channel: "C1", threadTS: nil, text: "x", selection: NSRange()))
    try s.saveDraft(Draft(channel: "C1", threadTS: nil, text: "  \n ", selection: NSRange()))
    #expect(try s.draft("C1", thread: nil) == nil)
    try s.saveDraft(Draft(channel: "C1", threadTS: "2.0", text: "y", selection: NSRange()))
    try s.clearDraft("C1", thread: "2.0")
    #expect(try s.drafts().isEmpty)
}

@Test func uiKeysRoundTrip() throws {
    let s = try makeStore()
    try s.setUI(.current, "C1")
    try s.setUI(.openThread, ThreadRef(channel: "C1", ts: "1.0"))
    let sections = [SectionState(id: "s1", name: "Customers", icon: "🏢", channels: ["C1"], collapsed: true, sort: .recent)]
    try s.setUI(.sections, sections)
    try s.setUI(.starred, ["C2"])
    try s.setUI(.sidebarVisible, false)
    try s.setUI(.sidebarWidth, 240.5)
    try s.setUI(.frequentEmoji, ["eyes": 3])
    try s.setUI(.scroll("C1"), ScrollAnchor(ts: "5.0", offset: -12))
    #expect(try s.ui(.current) == "C1")
    #expect(try s.ui(.openThread) == ThreadRef(channel: "C1", ts: "1.0"))
    #expect(try s.ui(.sections) == sections)
    #expect(try s.ui(.starred) == ["C2"])
    #expect(try s.ui(.sidebarVisible) == false)
    #expect(try s.ui(.sidebarWidth) == 240.5)
    #expect(try s.ui(.frequentEmoji) == ["eyes": 3])
    #expect(try s.ui(.scroll("C1")) == ScrollAnchor(ts: "5.0", offset: -12))
    #expect(try s.ui(.scroll("C9")) == nil)
    try s.setUI(.current, nil)
    #expect(try s.ui(.current) == nil)
}

@Test func uiKeyThatDoesNotDecodeThrows() throws {
    let s = try makeStore()
    try s.setValue(UIKey<ScrollAnchor>.scroll("C1").name, "{\"ts\": 5}")
    #expect(throws: LocalStateError.self) { try s.ui(.scroll("C1")) }
}

@Test func uiKeysDoNotCollideWithLegacyKV() throws {
    let s = try makeStore()
    s.set("ui.current", "C1")
    #expect(try s.ui(.current) == nil)
}
