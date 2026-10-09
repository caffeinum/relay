import Foundation

/// Everything the app can do. The key router and ⌘K both read `Commands.all`,
/// so a key without a command (or a command missing from ⌘K) can't exist.
public enum CommandID: String, CaseIterable, Codable {
    case cursorDown, cursorUp, top, bottom
    case reply, edit, delete, react, quick1, quick2, quick3, undo, copyLink, copyText, save, markUnread, openInSlack
    case focusComposer, toggleFocus, escape
    case jumpUnreads, nextUnread, prevUnread, nextConversation, prevConversation, jumpToNew, nextMention
    case markAllRead, search, palette, findConversation, refresh
    case toggleSidebar, toggleThread, closeThread, threads, drafts, editLast
    case star, moveToSection, newSection, renameSection, deleteSection, collapseSection, collapseAll
    case copyChannelLink, back, forward
    case toggleAppearance, switchWorkspace, openLog, openConfig, revealDatabase, quit
}

public struct Command: Equatable {
    /// global: a ⌘ chord that works while typing. list: a bare key, only when
    /// no text field has focus. message: a bare key on the cursor message.
    /// palette: only from ⌘K.
    public enum Scope: Equatable { case global, list, message, palette }
    public var id: CommandID
    public var title: String
    /// As shown on keycaps and matched by the router: "j", "g u", "⌥⇧↓", "⌘K", "⇧esc".
    public var keys: [String]
    public var scope: Scope
    public var symbol: String

    public init(_ id: CommandID, _ title: String, _ keys: [String], _ scope: Scope, _ symbol: String) {
        self.id = id; self.title = title; self.keys = keys; self.scope = scope; self.symbol = symbol
    }
}

public enum Commands {
    public static let all: [Command] = [
        Command(.cursorDown, "Next message", ["j", "↓"], .list, "arrow.down"),
        Command(.cursorUp, "Previous message", ["k", "↑"], .list, "arrow.up"),
        Command(.top, "Oldest loaded message", ["g g"], .list, "arrow.up.to.line"),
        Command(.bottom, "Newest message", ["G", "⌘↓"], .list, "arrow.down.to.line"),
        Command(.reply, "Reply in thread", ["r"], .message, "bubble.left"),
        Command(.edit, "Edit message", ["e"], .message, "pencil"),
        Command(.delete, "Delete message", ["⌫", "d"], .message, "trash"),
        Command(.react, "Add reaction…", ["+"], .message, "face.smiling"),
        Command(.quick1, "Quick reaction 1", ["1"], .message, "hand.thumbsup"),
        Command(.quick2, "Quick reaction 2", ["2"], .message, "eyes"),
        Command(.quick3, "Quick reaction 3", ["3"], .message, "checkmark.circle"),
        Command(.undo, "Undo send, edit or delete", ["z"], .list, "arrow.uturn.backward"),
        Command(.copyLink, "Copy link to message", ["c"], .message, "link"),
        Command(.copyText, "Copy message text", [], .message, "doc.on.doc"),
        Command(.save, "Save for later", ["s"], .message, "bookmark"),
        Command(.markUnread, "Mark unread from here", ["u"], .message, "envelope.badge"),
        Command(.openInSlack, "Open in Slack", ["⌘⇧O"], .global, "safari"),
        Command(.focusComposer, "Focus composer", ["i", "↩"], .list, "text.cursor"),
        Command(.toggleFocus, "Switch list and thread", ["⇥"], .list, "rectangle.split.2x1"),
        Command(.escape, "Mark channel read", ["esc"], .list, "checkmark"),
        Command(.jumpUnreads, "Jump to unreads", ["g u"], .list, "tray"),
        Command(.nextUnread, "Next unread conversation", ["⌥⇧↓"], .list, "arrow.down.circle"),
        Command(.prevUnread, "Previous unread conversation", ["⌥⇧↑"], .list, "arrow.up.circle"),
        Command(.nextConversation, "Next conversation", ["⌥↓"], .list, "chevron.down"),
        Command(.prevConversation, "Previous conversation", ["⌥↑"], .list, "chevron.up"),
        Command(.jumpToNew, "Jump to new messages", ["g n"], .list, "arrow.up.to.line"),
        Command(.nextMention, "Next mention", ["g m"], .list, "at"),
        Command(.markAllRead, "Mark all read", ["⇧esc"], .list, "checkmark.circle"),
        Command(.search, "Search messages", ["/", "⌘F"], .global, "magnifyingglass"),
        Command(.palette, "Command palette", ["⌘K"], .global, "command"),
        Command(.findConversation, "Find a conversation", ["⌘T", "t"], .global, "text.magnifyingglass"),
        Command(.refresh, "Refresh", ["⌘R"], .global, "arrow.clockwise"),
        Command(.toggleSidebar, "Toggle sidebar", ["⌘⇧D"], .global, "sidebar.left"),
        Command(.toggleThread, "Toggle thread pane", [], .palette, "sidebar.right"),
        Command(.closeThread, "Close thread", [], .palette, "xmark"),
        Command(.threads, "Threads", ["g t"], .list, "bubble.left.and.text.bubble.right"),
        Command(.drafts, "Drafts", ["g d"], .list, "paperplane"),
        Command(.editLast, "Edit last message", [], .palette, "pencil.line"),
        Command(.star, "Star / unstar channel", ["⌘⇧S"], .global, "star"),
        Command(.moveToSection, "Move channel to section…", [], .palette, "folder"),
        Command(.newSection, "New section…", [], .palette, "folder.badge.plus"),
        Command(.renameSection, "Rename section…", [], .palette, "character.cursor.ibeam"),
        Command(.deleteSection, "Delete section…", [], .palette, "folder.badge.minus"),
        Command(.collapseSection, "Collapse / expand section…", [], .palette, "chevron.right"),
        Command(.collapseAll, "Collapse all sections", [], .palette, "rectangle.compress.vertical"),
        Command(.copyChannelLink, "Copy channel link", [], .palette, "link"),
        Command(.back, "Back", ["⌘["], .global, "chevron.left"),
        Command(.forward, "Forward", ["⌘]"], .global, "chevron.right"),
        Command(.toggleAppearance, "Toggle dark / light", [], .palette, "circle.lefthalf.filled"),
        Command(.switchWorkspace, "Switch workspace…", [], .palette, "building.2"),
        Command(.openLog, "Open log file", [], .palette, "doc.text"),
        Command(.openConfig, "Open config", [], .palette, "gearshape"),
        Command(.revealDatabase, "Reveal database in Finder", [], .palette, "externaldrive"),
        Command(.quit, "Quit", ["⌘Q"], .global, "power"),
    ]

    public static let byID: [CommandID: Command] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static let byKey: [String: Command] = {
        var m: [String: Command] = [:]
        for c in all { for k in c.keys { m[k] = c } }
        return m
    }()

    public static func command(for key: String) -> Command? { byKey[key] }

    /// "g" starts a sequence when some command is bound to "g <x>".
    public static func startsSequence(_ key: String) -> Bool {
        all.contains { $0.keys.contains { $0.hasPrefix(key + " ") } }
    }

    /// The router's name for a key press: bare printable characters as typed
    /// (so ⇧ is already in "G" and "+"), named keys and chords with their
    /// modifiers in the order ⌃⌥⌘⇧ (as the spec writes ⌘⇧S and ⌥⇧↓).
    public static func keyName(chars: String, keyCode: UInt16, control: Bool, option: Bool, shift: Bool, command: Bool) -> String? {
        let named: [UInt16: String] = [125: "↓", 126: "↑", 123: "←", 124: "→", 53: "esc", 36: "↩", 76: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 49: "space"]
        var mods = ""
        if control { mods += "⌃" }
        if option { mods += "⌥" }
        if let n = named[keyCode] {
            if command { mods += "⌘" }
            if shift { mods += "⇧" }
            return mods + n
        }
        guard let c = chars.first, !chars.isEmpty else { return nil }
        if command || control || option {
            if command { mods += "⌘" }
            if shift { mods += "⇧" }
            return mods + String(c).uppercased()
        }
        return String(c)
    }
}
