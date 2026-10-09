import Foundation
import RelayCore

// Stand-ins for the CORE contracts in dev/spec/plan.md §3 that RENDER reads.
// Types are copied verbatim; new members of existing types return "nothing
// yet". `git rm` this file when CORE has merged; the compiler then names any drift.

public struct Unfurl: Equatable {
    public var title: String?; public var text: String?; public var serviceName: String?
    public var url: String?; public var color: String?; public var thumb: String?
}

public enum OutboxKind: String, Codable { case send, edit, delete }
public enum OutboxState: String, Codable { case pending, sending, sent, failed, cancelled }

public struct LocalEcho: Equatable {
    public var outbox: Int64
    public var kind: OutboxKind
    public var state: OutboxState
    public var sendsAt: Date?
    public var error: String?
    public var original: String?
}

public struct Person: Equatable {
    public var id: String; public var handle: String; public var displayName: String; public var realName: String
    public var isBot: Bool; public var botID: String?; public var deleted: Bool
    public var image48: String?; public var title: String?; public var tz: String?
    public var label: String { [displayName, realName].first { !$0.isEmpty } ?? handle }
}

public struct ScrollAnchor: Codable, Equatable { public var ts: String; public var offset: Double }

public enum MentionTarget: Hashable, Codable { case user(String), group(String), channel(String), special(String) }
public struct MentionToken: Equatable { public var range: NSRange; public var target: MentionTarget; public var label: String }

public enum Mentions {
    public static func encode(_ display: String, tokens: [MentionToken]) -> String {
        display.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    public static func decode(_ mrkdwn: String, label: (MentionTarget) -> String?) -> (text: String, tokens: [MentionToken]) {
        (mrkdwn.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&"), [])
    }
}

extension Message {
    public var editedTS: String? { nil }
    public var botID: String? { nil }
    public var isBot: Bool { false }
    public var avatar: String? { nil }
    public var isMine: Bool { false }
    public var mentionsMe: Bool { false }
    public var replyUsers: [String] { [] }
    public var unfurls: [Unfurl] { [] }
    public var local: LocalEcho? { nil }
    public var isSystem: Bool { ["channel_join", "channel_leave", "channel_topic", "channel_purpose"].contains(subtype ?? "") }
}
