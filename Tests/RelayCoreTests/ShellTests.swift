import Foundation
import Testing
@testable import RelayCore

private func conv(_ id: String, _ name: String, _ kind: Conversation.Kind = .channel, unread: Int = 0, latest: String = "1.000000", draft: Bool = false) -> Conversation {
    Conversation(id: id, name: name, kind: kind, latest: latest, unread: unread, hasDraft: draft)
}

// MARK: fuzzy

@Test func fuzzyPrefersPrefixThenWordStartThenSubsequence() {
    let f = Fuzzy(["engineering", "#ext-eng-2027dev", "design engine", "green", "eagle navigation group"])
    let order = f.rank("eng", limit: 10).map(\.0)
    #expect(order.first == 0)
    #expect(Set(order.prefix(3)) == [0, 1, 2])
    #expect(order.contains(3) == false || order.firstIndex(of: 3)! > 2)
    #expect(order.last == 4)
}

@Test func fuzzyNeedsEveryWord() {
    let f = Fuzzy(["mark all read", "mark channel read", "refresh"])
    #expect(f.rank("mark all", limit: 5).map(\.0) == [0])
    #expect(f.rank("zz", limit: 5).isEmpty)
    #expect(f.rank("", limit: 5).isEmpty)
}

@Test func fuzzyTenThousandItemsUnderBudget() {
    let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
    let hay = (0..<10_000).map { i in "\(words[i % 8])-\(words[(i / 8) % 8]) channel \(i)" }
    let f = Fuzzy(hay)
    _ = f.rank("de ch", limit: 50)
    let ms = fastest(5) { _ = f.rank("dch", limit: 50) } * 1000
    #if DEBUG
    let budget = 80.0
    #else
    let budget = 8.0
    #endif
    #expect(ms < budget, "rank took \(ms)ms")
}

// MARK: commands

@Test func everyCommandIDHasOneEntryAndKeysAreUnique() {
    let ids = Commands.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(Set(ids) == Set(CommandID.allCases))
    let keys = Commands.all.flatMap(\.keys)
    #expect(Set(keys).count == keys.count, "a key is bound twice")
    for k in keys { #expect(Commands.command(for: k) != nil) }
}

@Test func keyNamesMatchTheTable() {
    #expect(Commands.keyName(chars: "j", keyCode: 38, control: false, option: false, shift: false, command: false) == "j")
    #expect(Commands.keyName(chars: "G", keyCode: 5, control: false, option: false, shift: true, command: false) == "G")
    #expect(Commands.keyName(chars: "k", keyCode: 40, control: false, option: false, shift: false, command: true) == "⌘K")
    #expect(Commands.keyName(chars: "d", keyCode: 2, control: false, option: false, shift: true, command: true) == "⌘⇧D")
    #expect(Commands.keyName(chars: "", keyCode: 125, control: false, option: true, shift: true, command: false) == "⌥⇧↓")
    #expect(Commands.keyName(chars: "\u{1b}", keyCode: 53, control: false, option: false, shift: true, command: false) == "⇧esc")
    #expect(Commands.command(for: "⌥⇧↓")?.id == .nextUnread)
    #expect(Commands.startsSequence("g"))
    #expect(!Commands.startsSequence("j"))
}

// MARK: sections

@Test func sectionsPlaceEachConversationOnceFirstMatchWins() {
    let cs = [conv("C1", "general"), conv("C2", "customers"), conv("C3", "design"), conv("D1", "Mira", .im)]
    let sections = [SectionState(id: "a", name: "A", channels: ["#customers", "C3"]),
                    SectionState(id: "b", name: "B", channels: ["customers", "ghost"])]
    let p = Sections.place(cs, sections: sections, starred: ["C1"], current: nil, drafts: [])
    #expect(p.groups.map(\.name) == ["Starred", "A", "B", "Direct messages"])
    #expect(p.groups[0].rows.map(\.id) == ["C1"])
    #expect(p.groups[1].rows.map(\.id).sorted() == ["C2", "C3"])
    #expect(p.groups[2].rows.isEmpty)
    #expect(p.groups[3].rows.map(\.id) == ["D1"])
    #expect(p.missing == ["ghost"])
}

@Test func collapsedSectionKeepsUnreadSelectedAndDraftRows() {
    let cs = [conv("C1", "a"), conv("C2", "b", unread: 2), conv("C3", "c"), conv("C4", "d", draft: true), conv("C5", "e")]
    let s = [SectionState(id: "x", name: "X", channels: ["C1", "C2", "C3", "C4", "C5"], collapsed: true)]
    let p = Sections.place(cs, sections: s, starred: [], current: "C3", drafts: [])
    #expect(Set(p.groups[0].rows.map(\.id)) == ["C2", "C3", "C4"])
    #expect(p.groups[0].hidden == 2)
}

@Test func recentSortPutsUnreadFirstThenNewest() {
    let cs = [conv("C1", "a", latest: "5.000000"), conv("C2", "b", unread: 1, latest: "1.000000"), conv("C3", "c", latest: "9.000000")]
    let p = Sections.place(cs, sections: [], starred: [], current: nil, drafts: [])
    #expect(p.groups[0].rows.map(\.id) == ["C2", "C3", "C1"])
}

@Test func moveTakesAChannelOutOfEveryOtherSection() {
    let s = [SectionState(id: "a", name: "A", channels: ["#design", "C9"]), SectionState(id: "b", name: "B", channels: [])]
    let moved = Sections.move("C3", to: "b", in: s, aliases: ["design"])
    #expect(moved[0].channels == ["C9"])
    #expect(moved[1].channels == ["C3"])
    #expect(Sections.move("C3", to: nil, in: moved)[1].channels.isEmpty)
}

// MARK: mentions

@Test func mentionRankingPutsMembersFirstAndSpecialsLast() {
    let people = [Person(id: "U1", handle: "mira", displayName: "Mira Chen", realName: "Mira Chen"),
                  Person(id: "U2", handle: "miles", displayName: "Miles", realName: "Miles Davis"),
                  Person(id: "U3", handle: "deploybot", displayName: "deploybot", isBot: true)]
    let groups = [UserGroup(id: "S1", handle: "mobile", name: "Mobile team", users: ["U1"])]
    let search = MentionSearch(MentionSearch.people(people, groups: groups, me: nil))
    let mi = search.rank("mi", members: ["U2"], recent: [], limit: 8).map(\.id)
    #expect(mi.prefix(2) == ["U2", "U1"])
    #expect(!mi.contains("here"))
    let all = search.rank("", members: [], recent: ["U3"], limit: 10).map(\.id)
    #expect(all.first == "U3")
    #expect(all.suffix(3) == ["here", "channel", "everyone"])
    #expect(search.rank("he", members: [], recent: [], limit: 3).first?.id == "here")
    #expect(search.rank("mob", members: [], recent: [], limit: 3).first?.id == "S1")
    #expect(search.rank("chen", members: [], recent: [], limit: 3).first?.id == "U1")
}

@Test func mentionRankingFiveThousandPeopleUnderBudget() {
    let people = (0..<5000).map { Person(id: "U\($0)", handle: "user\($0)", displayName: "Person \($0)", realName: "Real \($0)") }
    let search = MentionSearch(MentionSearch.people(people, groups: [], me: nil))
    let ms = fastest(5) { _ = search.rank("pers", members: [], recent: [], limit: 8) } * 1000
    #if DEBUG
    let budget = 40.0
    #else
    let budget = 2.0
    #endif
    #expect(ms < budget, "rank took \(ms)ms")
}
