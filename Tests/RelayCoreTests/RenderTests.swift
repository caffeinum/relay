import Foundation
import Testing
@testable import RelayCore

/// The one place tests build a Message, so a model change is a one-line fix.
func msg(_ ts: Double, _ user: String, _ text: String = "hi", subtype: String? = nil, replies: Int = 0, thread: String? = nil) -> Message {
    Message(id: 0, channel: "C1", ts: String(format: "%.6f", ts), threadTS: thread, user: user, author: user, text: text,
            subtype: subtype, replyCount: replies, latestReply: nil, reactions: [])
}

private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
private let day0 = 1_760_000_000.0 - 1_760_000_000.0.truncatingRemainder(dividingBy: 86400) + 3600 * 9

private func grouped(_ items: [ListItem]) -> [Bool] {
    items.compactMap { if case .message(_, let g) = $0 { return g }; return nil }
}

@Test func groupsSameAuthorWithinFiveMinutes() {
    let ms = [msg(day0, "U1"), msg(day0 + 60, "U1"), msg(day0 + 400, "U1"), msg(day0 + 410, "U2"), msg(day0 + 420, "U2")]
    let items = ListLayout.items(ms, unreadAfter: nil, inThread: false, calendar: cal)
    #expect(items.first == .day(cal.startOfDay(for: ms[0].date)))
    #expect(grouped(items) == [false, true, false, false, true])
}

@Test func systemMessagesThreadsAndDaysBreakGroups() {
    let ms = [msg(day0, "U1", replies: 2), msg(day0 + 10, "U1"), msg(day0 + 20, "U1", subtype: "channel_join"),
              msg(day0 + 30, "U1"), msg(day0 + 86400, "U1")]
    let items = ListLayout.items(ms, unreadAfter: nil, inThread: false, calendar: cal)
    #expect(grouped(items) == [false, false, false, false, false])
    #expect(items.filter { if case .day = $0 { return true }; return false }.count == 2)
}

@Test func unreadDividerGoesBeforeFirstNewerMessageAndBreaksGroup() {
    let ms = [msg(day0, "U1"), msg(day0 + 10, "U1"), msg(day0 + 20, "U1")]
    let items = ListLayout.items(ms, unreadAfter: ms[0].ts, inThread: false, calendar: cal)
    #expect(items == [.day(cal.startOfDay(for: ms[0].date)), .message(index: 0, grouped: false), .unread,
                      .message(index: 1, grouped: false), .message(index: 2, grouped: true)])
    #expect(!ListLayout.items(ms, unreadAfter: ms[2].ts, inThread: false, calendar: cal).contains(.unread))
}

@Test func threadPaneHasReplyDividerUnderParent() {
    let ms = [msg(day0, "U1", replies: 2), msg(day0 + 10, "U1"), msg(day0 + 20, "U1")]
    let items = ListLayout.items(ms, unreadAfter: nil, inThread: true, calendar: cal)
    #expect(items == [.day(cal.startOfDay(for: ms[0].date)), .message(index: 0, grouped: false), .threadReplies(count: 2),
                      .message(index: 1, grouped: false), .message(index: 2, grouped: true)])
}

@Test func tsComparesNumerically() {
    #expect(ListLayout.tsLess("999.000100", "1000.000001"))
    #expect(ListLayout.tsLess("1000.000001", "1000.000002"))
    #expect(!ListLayout.tsLess("1000.1", "1000.1"))
}

@Test func dayLabels() {
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15))!
    #expect(DayLabel.string(now, now: now, calendar: cal) == "Today")
    #expect(DayLabel.string(now.addingTimeInterval(-86400), now: now, calendar: cal) == "Yesterday")
    #expect(DayLabel.string(cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!, now: now, calendar: cal) == "Thursday, October 1st")
    #expect(DayLabel.string(cal.date(from: DateComponents(year: 2025, month: 10, day: 22))!, now: now, calendar: cal) == "October 22nd, 2025")
    #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map(DayLabel.ordinal) == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"])
}

@Test func timeLabels() {
    let c = Calendar.current
    let now = c.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 18, minute: 0))!
    let t = c.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 16, minute: 52))!
    #expect(TimeLabel.short(t, now: now) == "4:52 PM")
    #expect(TimeLabel.short(t.addingTimeInterval(-86400), now: now) == "Yesterday at 4:52 PM")
    #expect(TimeLabel.short(c.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9, minute: 5))!, now: now) == "Oct 3rd at 9:05 AM")
    #expect(TimeLabel.gutter(t) == "4:52")
}

@Test func emojiSearchRanksPrefixThenFrequency() {
    let r = EmojiSearch.rank("thu", frequent: ["thumbsdown": 5], custom: ["thunk": "https://x/thunk.png"], limit: 4)
    #expect(r.first == "thumbsdown")
    #expect(r.contains("thumbsup"))
    #expect(r.contains("thunk"))
    #expect(EmojiSearch.rank("eyes", frequent: [:], custom: [:], limit: 1) == ["eyes"])
    #expect(EmojiSearch.rank("", frequent: ["a": 1, "b": 3], custom: [:], limit: 5) == ["b", "a"])
}
