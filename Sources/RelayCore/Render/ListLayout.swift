import Foundation

public enum ListItem: Equatable {
    case message(index: Int, grouped: Bool)
    case day(Date)
    case unread
    case threadReplies(count: Int)
}

/// The rows of a message list: messages with their grouping, plus the day
/// separators, the "New" divider and the thread pane's reply divider.
public enum ListLayout {
    public static let groupWindow: TimeInterval = 300
    static let systemSubtypes: Set<String> = ["channel_join", "channel_leave", "channel_topic", "channel_purpose", "channel_name", "group_join", "group_leave"]

    /// `unreadAfter` is the read cursor: the divider goes before the first
    /// message newer than it. In a thread, `ms[0]` is the parent.
    public static func items(_ ms: [Message], unreadAfter: String?, inThread: Bool, calendar: Calendar = .current) -> [ListItem] {
        var out: [ListItem] = []
        out.reserveCapacity(ms.count + 8)
        var dividerPlaced = unreadAfter == nil
        var lastDay: Date?
        var prev: Message?
        var prevDate = Date.distantPast
        for (i, m) in ms.enumerated() {
            let date = m.date
            var broken = false
            let day = calendar.startOfDay(for: date)
            if day != lastDay {
                // The thread pane's header already frames the parent: its day shows only where replies change day.
                if !(inThread && i == 0) { out.append(.day(day)) }
                lastDay = day
                broken = true
            }
            if !dividerPlaced, let after = unreadAfter, !(inThread && i == 0), tsLess(after, m.ts) {
                out.append(.unread)
                dividerPlaced = true
                broken = true
            }
            var grouped = false
            if !broken, let p = prev, !p.user.isEmpty, p.user == m.user, date.timeIntervalSince(prevDate) < groupWindow,
               date >= prevDate, !isSystem(p), !isSystem(m), !isBroadcast(p), !isBroadcast(m),
               !(inThread && i == 1), inThread || p.replyCount == 0 {
                grouped = true
            }
            out.append(.message(index: i, grouped: grouped))
            if inThread, i == 0, ms.count > 1 { out.append(.threadReplies(count: ms.count - 1)) }
            prev = m
            prevDate = date
        }
        return out
    }

    static func isSystem(_ m: Message) -> Bool { m.subtype.map(systemSubtypes.contains) ?? false }
    static func isBroadcast(_ m: Message) -> Bool { m.subtype == "thread_broadcast" }

    /// Slack ts strings compare as decimals, not as text ("9.1" < "10.1").
    public static func tsLess(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: ".", maxSplits: 1), y = b.split(separator: ".", maxSplits: 1)
        let xi = x.first.map(String.init) ?? "", yi = y.first.map(String.init) ?? ""
        if xi.count != yi.count { return xi.count < yi.count }
        if xi != yi { return xi < yi }
        return (x.count > 1 ? String(x[1]) : "") < (y.count > 1 ? String(y[1]) : "")
    }
}

public enum DayLabel {
    public static func string(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        let sameYear = calendar.component(.year, from: d) == calendar.component(.year, from: now)
        f.dateFormat = sameYear ? "EEEE, MMMM" : "MMMM"
        let day = ordinal(calendar.component(.day, from: d))
        return sameYear ? "\(f.string(from: d)) \(day)" : "\(f.string(from: d)) \(day), \(calendar.component(.year, from: d))"
    }

    public static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

public enum TimeLabel {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    /// K-3 "show seconds": set on main from config, read while drawing.
    public static var seconds = false
    private static let timeM = formatter("h:mm a"), timeS = formatter("h:mm:ss a")
    private static let gutterM = formatter("h:mm"), gutterS = formatter("h:mm:ss")
    private static let month = formatter("MMM")
    private static let full = formatter("EEEE, MMMM d, yyyy 'at' h:mm:ss a")

    /// "4:52 PM", "Yesterday at 4:52 PM", "Oct 3rd at 4:52 PM".
    public static func short(_ d: Date, now: Date = Date(), seconds: Bool = seconds) -> String {
        let time = seconds ? timeS : timeM
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return time.string(from: d) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday at " + time.string(from: d) }
        return "\(month.string(from: d)) \(DayLabel.ordinal(cal.component(.day, from: d))) at \(time.string(from: d))"
    }

    /// The avatar-gutter time on grouped rows: "4:52".
    public static func gutter(_ d: Date, seconds: Bool = seconds) -> String { (seconds ? gutterS : gutterM).string(from: d) }

    public static func tooltip(_ d: Date) -> String { full.string(from: d) }
}
