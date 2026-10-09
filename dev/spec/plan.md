# Relay build plan: Slack UX

Inputs: `design.md` (visual spec, cited as D§n), `product.md` (requirements, cited by ID such as O1 or K-3), and the reference screenshot.
The work splits into three tracks. CORE and RENDER run at the same time in worktrees. SHELL starts on main once both have merged.
Section 3 holds the contracts between them. If a contract has to change, the change goes into this file first, then into the code.

## 0. Spec conflicts, resolved

| topic | design says | product says | decision |
| --- | --- | --- | --- |
| where sections live | kv, seeded from config | `config.json`, rewritten atomically | **kv** (`UIKey.sections`). It is seeded once from `config.sections`, and ⌘K edits write kv. This avoids races on the config file, keeps sections per workspace, and needs no restart. |
| sidebar order | Starred, config sections, Channels, DMs | config sections, Starred, … | **Starred first** (the screenshot) |
| long lines in code blocks | clip | wrap inside the block | **wrap** (NSTextBlock does this for free, and nothing is hidden) |
| thread "also send to #channel" | checkbox | never; `reply_broadcast` is never true | **no checkbox** (T3) |
| draft debounce | 400 ms | 300 ms | **300 ms** |
| mark read | 1.5 s debounce | visible ~1 s, `conversations.mark` at most once per channel per 3 s | **local seen after 1 s visible, remote mark throttled to once per channel per 3 s** |
| find-a-conversation key | ⌘⇧K or `t` | ⌘T | **⌘T and `t`** |
| hover bar buttons | D§5.4 (8 buttons) | M4 (6 buttons) | **D§5.4** (a superset of M4) |
| day label | "Wednesday, October 7th" | "Tuesday, October 6" | **D§5.9** (with ordinals) |

## 1. Tracks, ownership, environment

| track | where | owns (may edit) | must not edit | emulator | env |
| --- | --- | --- | --- | --- | --- |
| **CORE** | worktree `../relay-core`, branch `core` | `Sources/RelayCore/*` **except** `Mrkdwn.swift` and `Render/`; `Sources/relayctl/*`; `Tests/RelayCoreTests/{Store,Outbox,Drafts,Mentions,Live,Sync}*Tests.swift`; `dev/emulator.sh`, `dev/emulate.yaml`, `dev/slack-manifest.json`, `dev/store-token.sh` | anything in `Sources/Relay/` | `PORT=4013 dev/emulator.sh` | `RELAY_HOME=/tmp/relay-core RELAY_CONFIG=/tmp/relay-core/config.json` |
| **RENDER** | worktree `../relay-render`, branch `render` | `Sources/RelayCore/Mrkdwn.swift`; **new** files under `Sources/RelayCore/Render/`; `Sources/Relay/MessageList.swift`, `Sources/Relay/Emoji.swift`; **new** `Sources/Relay/` files (`Theme.swift`, `MessageRow*.swift`, `Avatars.swift`, `HoverBar.swift`, `ReactionStrip.swift`, `ThreadSummary.swift`, `ListOverlays.swift`, `InlineEditor.swift`, `CoreStubs.swift`); `Tests/RelayCoreTests/{Mrkdwn,Render*}Tests.swift`; new `dev/seed-render.sh` | every other RelayCore file; `MainController`, `Sidebar`, `Overlays`, `Chrome`, `AppDelegate`, `Script` (one exception, below) | `PORT=4023 dev/emulator.sh && PORT=4023 dev/seed-render.sh` | `RELAY_HOME=/tmp/relay-render RELAY_CONFIG=/tmp/relay-render/config.json` |
| **SHELL** | main tree, after both merge | everything else in `Sources/Relay/`; **new** files under `Sources/RelayCore/Shell/` (fuzzy matcher, command table, section placement), with tests | — | `PORT=4003 dev/emulator.sh` | `RELAY_HOME=/tmp/relay-shell RELAY_CONFIG=/tmp/relay-shell/config.json` |

RENDER's one exception is `Script.swift`. It may add new script verbs (`hover <row>`, `click <x> <y>`, `scroll <dy>`), and only as added `case` lines. Nobody else touches that file before SHELL starts.

Every config used by a track sets `"workspace": "emulator"` and `"emulator": {"api": "http://localhost:<port>/api", "token": "xoxp-emu-aleks", "writes": true}`.
`2027dev` stays `writes:false` everywhere. Nobody runs a write method against slack.com. Don't kill another track's emulator: each tmux session is named `relay-emulator-<port>`.

Every app run is headless:
`RELAY_HEADLESS=1 RELAY_SCRIPT="wait 1.5; …; snap /tmp/relay-<role>/x.png; quit" build/Relay.app/Contents/MacOS/Relay`

Each track runs the gate before every commit: `./build.sh debug && ./test.sh`. Before a merge, it also runs `./build.sh release && build/relayctl bench 8`. Record the median in the commit message. It must not get worse than the baseline on main (measure the baseline first, and write it down at the top of the PR).

### Keeping both worktrees building

- **CORE is additive for every symbol that `Sources/Relay` uses today.** These keep working with the same meaning: `Store.{get,set,me,name(of:),conversations(),messages(_:limit:),thread(_:ts:),search,syncState,markSeen,messageCount}`, every current field of `Message` (`edited: Bool` becomes a computed property over `editedTS`), every current field of `Conversation`, `Config.Section.{name,channels}`, `Sync.{run,all,newer,older,thread,remoteSearch,onChange,onError,onProgress,slack,store}`, `Hit`, and `Slack.writes`. The rewrites happen in SHELL.
- **RENDER builds against stubs.** `Sources/Relay/CoreStubs.swift` declares every CORE type and member in §3.1 that RENDER reads. Types are copied verbatim. New members of existing types become computed properties in extensions that return the "nothing yet" value (`nil`, `[]`, `false`). RENDER never adds stored state there. At merge, delete `CoreStubs.swift`, and the compiler then points at any drift. If a stubbed name doesn't match §3.1 exactly, that's a bug in the RENDER PR.
- **RENDER keeps `MessageList`'s current surface** (`names`, `onNearTop`, `onOpen`, `show(_:keep:cursor:)`, `select`, `step`, `messages`, `selectedMessage`, `selected`, `focused`, `empty`, `inThread`, `table`, `scrollToBottom`), so `MainController` compiles unchanged. SHELL removes the old members once it has moved to the new ones.

### Merge order

1. CORE → main: rebase onto main, then gate, bench, merge.
2. RENDER → main: rebase onto the new main, `git rm Sources/Relay/CoreStubs.swift`, fix any compile drift (the contracts say what's correct), then gate, bench, merge.
3. SHELL starts on main.

---

## 2. Work breakdown

### CORE (RelayCore, relayctl, tests)

Do these in order. Each numbered item is a commit with tests.

1. **Schema v2, done as stepwise migrations.** `migrate()` runs one block per version: `if v < 2 { …; PRAGMA user_version=2 }`. A database at v1 upgrades in place, with no data loss. Changes:
   - `messages`: add `bot_id TEXT`, `username TEXT`, `edited_ts TEXT`, `attachments TEXT`. Keep `edited` and backfill it.
   - `users`: add `image_48 TEXT`, `title TEXT`, `tz TEXT`, `bot_id TEXT`.
   - new tables:
     - `conv_meta(id PK, topic, member_count, is_member, user_is_bot)`
     - `members(channel, user, PK(channel,user))`
     - `bots(id PK, name, user_id, image_48, updated)`
     - `usergroups(id PK, handle, name, users TEXT /*json*/, updated)`
     - `emoji(name PK, value /*url or alias:x*/)`
     - `drafts(channel, thread_ts NOT NULL DEFAULT '', text, sel_loc, sel_len, updated REAL, PK(channel, thread_ts))`
     - `outbox(id INTEGER PK, kind, state, channel, thread_ts, target_ts, local_ts, text, original, error, created REAL, sends_at REAL, sent_ts)`
     - `events(id PK, at REAL)` for dedup, pruned after 1 h
   - indexes:
     - `CREATE INDEX messages_top ON messages(channel, ts) WHERE thread_ts IS NULL OR thread_ts = ts`
     - `CREATE INDEX outbox_live ON outbox(channel, state)`
2. **Model fields** (§3.1) are filled by `Store.message(_:)`. Author resolution goes, in order: the user's name, `bots.name`, the message `username`. When a message has neither a user nor a `bot_id`, write a `log("message <c>/<ts> has no user or bot_id")` line (once per ts per process) and keep `user = ""`. Never write "unknown" (M6).
3. **Slack write methods** (§3.3). All of them go through `call` and are blocked by the existing write gate. Add a test where a `URLProtocol` fails if any request is sent while writes are off (G1).
4. **Outbox** (§3.4) with local echo merged into `messages()`/`thread()`. It covers the state machine pending → sending → sent | failed, plus pending → cancelled. On launch it runs `resume()`, which moves `pending` and `sending` items to `failed("not sent: app quit")` (O3). Clearing the draft happens in the same transaction as the insert. Tests cover each state transition, undo, too-late undo, a failure rollback, and an echo that arrives before the HTTP reply.
5. **Reactions, mark, open DM** (§3.5). Reactions are optimistic, and the store changes synchronously. `already_reacted`/`no_reaction` are reconciled through `reactions.get` without a toast. Any other error reverts the change and reaches `onError`.
6. **Drafts and UI state** (§3.6). The kv helpers throw. Keep `set(_:_:)` as a wrapper that logs failures, until SHELL moves to `setUI`.
7. **People, bots, usergroups, members, emoji** (§3.7). Sync fetches `usergroups.list include_users=true` and `emoji.list` once a day, `conversations.members` on open (when the cache is more than a day old), `bots.info` for unseen `bot_id`s, and `users.info` for unknown `<@U>` and author ids after each `put(messages:)`. When the emulator returns `unknown_method` or another error for `emoji.list` or `usergroups.list`, log it once per process, store `emoji.unavailable`/`usergroups.unavailable` in kv with the error text, and return an empty set from the store. Nothing is fabricated.
8. **Mention encoding** (§3.8), as pure functions with round-trip tests (A2, K3).
9. **Live** (§3.9). Socket Mode over `URLSessionWebSocketTask`, and a poll fallback. `EventApplier` is pure and tested against JSON fixtures in `Tests/RelayCoreTests/Fixtures/` (add `resources: [.copy("Fixtures")]` to the test target in Package.swift, which CORE may edit). The app token comes from the keychain account `<ws>.app` or, for emulators only, from config `appToken`.
10. **Unread divider data**: `Store.firstUnread(_:)` (§3.2).
11. **Per-frame performance**:
    - `relayctl seed-bench` writes a db of 100k messages across 200 channels.
    - `relayctl perf` prints p50/p95 for `conversations()`, `messages(c,200)` and `people()`.
    - Targets: `conversations()` under 10 ms, and `messages()` + `firstUnread()` under 2 ms on that db. Use `EXPLAIN QUERY PLAN` in a test to assert that both unread subqueries use `messages_top` or the unique index, not a scan.
    - The mentions subquery stays a LIKE over rows past `read`, which is bounded by the index range.
12. **relayctl verbs**: `send <#c> <text> [--thread ts]`, `edit <#c> <ts> <text>`, `delete <#c> <ts>`, `react <#c> <ts> <name>`, `mark <#c> [ts]`, `outbox`, `drafts`, `live` (connect and print events, without tokens), `seed-bench`, `perf`. Writes print the `writeBlocked` error when they're off.
13. **Emulator**: extend `dev/emulate.yaml`/`dev/emulator.sh` with a bot that posts, `profile.image_48` on users, and (once @emulate adds them) usergroups and emoji. Ask @emulate for the gaps in product §16. Socket Mode tests use the fixture applier until the emulator has a websocket.

### RENDER (message list and mrkdwn)

1. **`Theme.swift`**: every token in D§1.1 as `NSColor(name:dynamicProvider:)`, the D§1.2 fonts as `static let`, the D§1.3 radii and shadow helpers, and `Symbols.image(name, size, weight)` with a cache. `Palette` stays in `Chrome.swift`, unchanged, for SHELL to retire.
2. **Mrkdwn block parser** (§3.10), linear time. Tests: one per K1 construct, markers inside code left alone, `snake_case_name` left plain, entities unescaped exactly once, and a 20 KB message parsed in under 5 ms. `plain(_:names:)` keeps its signature, because `Store` calls it for fts. Delete `runs()` only after SHELL stops using it. RENDER moves `MessageList` off it.
3. **`RelayCore/Render/`** (pure and tested):
   - `ListLayout.items` (§3.11): grouping (5 min, same author or bot, no day break, no divider, no visible thread summary, no system subtype), date separators, the unread divider, and the thread "N replies" divider.
   - `DayLabel`, `TimeLabel` (D§5.1, D§5.9).
   - `EmojiData` (the full shortcode → unicode table with aliases and skin tones, a generated Swift literal, plus a `dev/gen-emoji.py` that produced it).
   - `EmojiSearch.rank(query:frequent:custom:)` (R2).
4. **Rows**:
   - one `MessageRowView: NSTableRowView` and one `MessageCellView` per kind (`message`, `day`, `unread`, `threadDivider`), each with its own identifier, all recycled through `makeView(withIdentifier:)`. `rowViewForRow` recycles too.
   - The cell holds one text view (drawing only; `NSTextView` with a custom layout manager for the inline code and mention rounded backgrounds), one avatar `CALayer`, one `ReactionStrip` (draws pills itself and hit-tests from `[PillLayout]`), one `ThreadSummaryView`, and a reserved unfurl slot.
5. **Render cache**: `RenderedMessage` built once per `(ts, editedTS, localStateTag)`. Heights are cached by `(ts, editedTS, reactionsHash, localStateTag, width)`, and hover or cursor changes never invalidate them. Measuring happens once per width. On a resize, re-measure only the rows in view first, and the rest in one deferred pass.
6. **Hover**: one `NSTrackingArea` on the table and one `hoveredRow` property. One shared `HoverBar` (a sibling of the clip view) moves between rows, per D§5.4. It includes the inline delete confirmation strip and the 400 ms "show on the still cursor" rule.
7. **Avatars** (`Avatars.swift`): initials on 8 hashed tones right away. When `image48` is known, the image is decoded off main into an LRU of 512 `CGImage`s, with a disk cache at `Paths.support/avatars/<id>-<hash>.png`. On load it calls `onLoad(userID)`, and the list reloads only the visible rows by that user.
8. **List overlays** (`ListOverlays.swift`, one instance each): the sticky day pill (binary search over `[dayStartRow]`), the jump-to-unread or mentions pill, and jump-to-bottom / "↓ N new".
9. **Scroll behavior** (D§5.11, U4, U6, U7): `ShowMode` (§3.12), the anchor-preserving prepend, `scrollAnchor` for SHELL to persist, and `atBottomVisible` firing for mark read.
10. **Inline editor** (`InlineEditor.swift`): one reusable view placed over the row, which overrides that row's height while it's open. Text comes from `Mentions.decode` (stubbed until CORE merges). It has the hint line and Save/Cancel buttons, and the yellow editing tint. ↩ calls `actions.saveEdit(message, mrkdwn)` with the result of `Mentions.encode`, and esc cancels. The text view comes from the `makeEditorTextView` factory, so SHELL can swap in the composer's text view.
11. **Local echo looks**: `pending` is drawn at 55% alpha with "Sending… z to undo", `failed` gets a red footnote "Not sent: <error> · ↩ retry", `deleting` collapses to "Deleted · z to undo", and `editing` shows the new text plus "(edited)".
12. **Seed**: `dev/seed-render.sh` posts code blocks, quotes, lists, mentions of people, bots, here and groups, reactions from several users, a long thread, messages across 3 days, and a bot message. Snap each case and Read the png.

### SHELL (main tree, after the merge)

1. **Sidebar redesign** (D§3): recycled rows of each kind, the workspace header, the find field (⌘T, `t`), the top items (Threads, Mentions, Drafts with a count), sections from `UIKey.sections` seeded from config, collapse that keeps unread, selected and draft rows visible, drafts pencils, badges, DM avatars with presence, the floating unread pill, and section commands. Placement logic lives in `RelayCore/Shell/Sections.swift`, with S1 tests.
2. **Composer** (D§7): an `NSTextView` that grows. ↩ sends, ⇧↩ adds a newline, and inside a fence ↩ adds a newline while ⌘↩ sends. It has the formatting keys, live styling of only the edited paragraph, and mention tokens as atomic attributes (`.relayMention`). The `@`/`#`/`:` popups rank in memory. Drafts autosave after 300 ms and on every switch, and are restored on open. ↑ in an empty composer edits my last message. `+:eyes:` reacts. When writes are off, it shows the read-only note.
3. **MainController wiring**: every `MessageActions` closure, `Outbox`/`Live`/`Sync` callbacks → `cacheChanged` and toasts, the ownership checks (E1), and every key in product §14, all routed through the command table.
4. **⌘K everything** (D§10, product §13): `RelayCore/Shell/Commands.swift` holds the `Command` table (id, title, keys, scope). Add a test that every key the router handles has a command. `RelayCore/Shell/Fuzzy.swift` keeps K-7 under 8 ms for 10k items, with a timing test. Sections: Conversations, People, Commands, Links (`list.visibleLinks` + fts), Messages (fts, 120 ms later), and "Open <url>". The prefixes are `# @ > / :`.
5. **Local state restore** (L3): the current conversation, the open thread, the scroll anchor per channel, collapsed sections, sidebar visibility and width, thread pane width, and recents. All of it is read before the first frame.
6. **Toasts** (D§9): stacking, success and error kinds, and the undo toast with a `strokeEnd` countdown.
7. Remove the compatibility members from MessageList, `Store.set`, `Mrkdwn.runs`, and `Palette`.

---

## 3. Contracts

All public. CORE types live in `Sources/RelayCore/` unless the heading says otherwise. RENDER's `CoreStubs.swift` mirrors 3.1, 3.2 (only the signatures it calls), 3.4's `LocalEcho` family, 3.7's `Person`, and 3.8.

### 3.1 Model (Store.swift)

```swift
public struct Conversation: Equatable {
    public enum Kind: String { case channel, `private`, im, mpim }
    public var id: String
    public var name: String            // mpim: member display names joined ", " (CORE resolves)
    public var kind: Kind
    public var userID: String?
    public var lastRead: String        // max(last_read, seen)
    public var latest: String
    public var unread: Int
    public var mentions: Int           // DMs: every unread counts
    // new
    public var topic: String?
    public var isSelf: Bool            // im with me
    public var userIsBot: Bool         // im with a bot
    public var hasDraft: Bool          // channel draft or any thread draft
    public var isDM: Bool { get }
    public var label: String { get }
}

public struct Message: Equatable {
    public var id: Int64               // local echo: -outbox.id
    public var channel: String
    public var ts: String              // local echo of a send: outbox.local_ts
    public var threadTS: String?
    public var user: String            // "" only when Slack sent neither user nor bot_id (logged)
    public var author: String          // resolved display name / bot name / username
    public var text: String            // mrkdwn source (for an edit echo: the new text)
    public var subtype: String?
    public var replyCount: Int
    public var latestReply: String?
    public var reactions: [SlackReaction]
    // new
    public var editedTS: String?
    public var botID: String?
    public var isBot: Bool
    public var avatar: String?         // image_48 URL, user's or bot's
    public var isMine: Bool
    public var mentionsMe: Bool        // <@me>, my usergroups, here/channel/everyone
    public var replyUsers: [String]    // up to 3, for the thread summary (empty until known)
    public var unfurls: [Unfurl]
    public var local: LocalEcho?       // nil = a server message
    public var edited: Bool { editedTS != nil }
    public var isSystem: Bool { get }  // channel_join, channel_leave, channel_topic, channel_purpose
    public var date: Date { get }
    public var isThreadReply: Bool { get }
}

public struct Unfurl: Equatable {
    public var title: String?; public var text: String?; public var serviceName: String?
    public var url: String?; public var color: String?; public var thumb: String?
}
```

`SlackMessage` gains `bot_id` (exists), `bot_profile {id, name, icons.image_48}`, `client_msg_id`, `attachments`, `reply_users`, and `edited.ts` (exists).

### 3.2 Store reads used per frame

```swift
extension Store {
    func conversations() throws -> [Conversation]                       // < 10 ms on 100k
    func conversation(_ id: String) throws -> Conversation?
    func messages(_ channel: String, limit: Int = 200) throws -> [Message]   // + local echo, oldest first
    func messages(_ channel: String, before ts: String, limit: Int) throws -> [Message]
    func thread(_ channel: String, ts: String) throws -> [Message]          // + local echo
    func firstUnread(_ channel: String) throws -> String?   // oldest top-level ts > lastRead not mine; nil if none
    func firstUnread(_ channel: String, thread ts: String) throws -> String?  // uses UIKey.threadRead
    func message(_ channel: String, ts: String) throws -> Message?
}
```

### 3.3 Slack writes (Slack.swift)

All of these throw `SlackError.writeBlocked(method)` when `writes == false`, before any I/O.

```swift
extension Slack {
    struct Posted: Codable { public var ts: String; public var channel: String; public var message: SlackMessage? }
    func post(channel: String, text: String, thread: String?) async throws -> Posted   // reply_broadcast never sent
    func update(channel: String, ts: String, text: String) async throws
    func delete(channel: String, ts: String) async throws
    func react(channel: String, ts: String, name: String, add: Bool) async throws       // reactions.add / .remove
    func reactions(channel: String, ts: String) async throws -> [SlackReaction]         // reactions.get (read)
    func mark(channel: String, ts: String) async throws                                  // conversations.mark
    func openDM(users: [String]) async throws -> SlackConversation                      // conversations.open
    func members(_ channel: String) async throws -> [String]                             // read
    func usergroups() async throws -> [SlackUserGroup]                                   // read
    func bot(_ id: String) async throws -> SlackBot                                      // read
    func user(_ id: String) async throws -> SlackUser                                    // read
    func emoji() async throws -> [String: String]                                        // read
    func connectionsOpen(appToken: String) async throws -> URL                           // apps.connections.open, bearer = xapp
}
```

`reads` gains `usergroups.list`, `bots.info`, `emoji.list` and `users.info`. Write methods are `chat.postMessage`, `chat.update`, `chat.delete`, `reactions.add`, `reactions.remove`, `conversations.mark` and `conversations.open`.

### 3.4 Outbox (Outbox.swift)

```swift
public enum OutboxKind: String, Codable { case send, edit, delete }
public enum OutboxState: String, Codable { case pending, sending, sent, failed, cancelled }

public struct LocalEcho: Equatable {
    public var outbox: Int64
    public var kind: OutboxKind
    public var state: OutboxState      // only pending, sending, failed reach the UI
    public var sendsAt: Date?          // pending only: end of the undo window
    public var error: String?          // failed only, Slack's error word for word
    public var original: String?       // edit: text before the edit
}

public struct OutboxItem: Equatable {
    public var id: Int64; public var kind: OutboxKind; public var state: OutboxState
    public var channel: String; public var threadTS: String?
    public var targetTS: String?       // edit/delete: the message; send: nil until sent
    public var localTS: String         // send: ordering ts of the echo
    public var text: String?; public var original: String?; public var error: String?
    public var created: Date; public var sendsAt: Date
}

public enum UndoResult: Equatable { case undone(OutboxItem), tooLate(OutboxItem), nothing }

public final class Outbox {
    public init(store: Store, slack: Slack, undoSeconds: Double = 5)
    public var undoSeconds: Double
    public var onChange: ((Set<String>) -> Void)?           // main queue; channels to redraw
    public var onError: ((OutboxItem, Error) -> Void)?       // main queue; caller toasts + logs
    /// Throws writeBlocked synchronously when writes are off; nothing is stored.
    @discardableResult public func send(channel: String, thread: String?, text: String) throws -> OutboxItem   // clears that draft in the same txn
    @discardableResult public func edit(_ m: Message, text: String) throws -> OutboxItem                       // throws OutboxError.notMine
    @discardableResult public func delete(_ m: Message) throws -> OutboxItem                                   // throws OutboxError.notMine
    public func undo() throws -> UndoResult        // newest pending → cancelled. tooLate = newest item sent within the last 30 s
    public func retry(_ id: Int64) throws          // failed → pending (a fresh window)
    public func discard(_ id: Int64) throws        // failed → cancelled, echo disappears
    public func resume() throws                    // at launch: pending/sending → failed("not sent: app quit")
    public func items(channel: String) throws -> [OutboxItem]
}

public enum OutboxError: Error, CustomStringConvertible { case notMine, notFound(Int64), notPending(Int64) }
```

How the echo merges: `messages()`/`thread()` read `outbox WHERE channel=? AND state IN (pending, sending, failed)`.

- A send adds a `Message` with `id = -item.id`, `ts = localTS`, `isMine = true`, and `local` set.
- An edit replaces the target's `text` and sets `editedTS = localTS` and `local`.
- A delete keeps the row with `local.kind == .delete`. RENDER draws it collapsed.

When a send succeeds, one transaction does `put(messages: [posted.message])` and sets the outbox row to `sent` with `sent_ts`. If Live delivers the echo first, its message from me with the same channel, thread and text resolves the oldest `sending` row.

### 3.5 Immediate actions (Sync.swift)

```swift
extension Sync {
    /// Flips my reaction in the store now, then calls Slack. Throws writeBlocked
    /// synchronously. Failure: reverts, then onError. already_reacted/no_reaction: reconcile, no error.
    public func toggleReaction(_ m: Message, _ name: String) throws
    /// Local seen now; conversations.mark at most once per channel per 3 s when writes are on.
    public func markRead(_ channel: String, ts: String)
    public func markThreadRead(_ channel: String, thread: String, ts: String)   // local only (UIKey.threadRead)
    public func markUnread(_ channel: String, before ts: String)                 // seen moves back; remote mark to the previous ts if writes
    public func markAllRead()                                                    // rate-limited loop
    public func openDM(_ user: String) async throws -> String                    // cached im id, else conversations.open, cached
    public func members(_ channel: String)                                       // fire-and-forget refresh if older than 1 day
}
```

### 3.6 Drafts and UI state (Store+Local.swift)

```swift
public struct Draft: Equatable {
    public var channel: String; public var threadTS: String?
    public var text: String            // display text with mention tokens encoded (Mentions.encode output)
    public var selection: NSRange; public var updated: Date
    public init(channel: String, threadTS: String?, text: String, selection: NSRange, updated: Date = Date())
}
extension Store {
    func draft(_ channel: String, thread: String?) throws -> Draft?
    func saveDraft(_ d: Draft) throws          // empty/whitespace text deletes the row
    func clearDraft(_ channel: String, thread: String?) throws
    func drafts() throws -> [Draft]            // newest first
    func draftThreads(_ channel: String) throws -> Set<String>
}

public struct UIKey<T: Codable> { public let name: String; public init(_ name: String) }
public struct ThreadRef: Codable, Equatable { public var channel: String; public var ts: String }
public struct ScrollAnchor: Codable, Equatable { public var ts: String; public var offset: Double }
public struct SectionState: Codable, Equatable {
    public enum Sort: String, Codable { case alpha, recent }
    public var id: String; public var name: String; public var icon: String?
    public var channels: [String]; public var collapsed: Bool; public var sort: Sort
}
extension UIKey where T == String { public static let current: UIKey<String> }
extension UIKey where T == ThreadRef { public static let openThread: UIKey<ThreadRef> }
extension UIKey where T == [SectionState] { public static let sections: UIKey<[SectionState]> }
extension UIKey where T == [String] { public static let starred: UIKey<[String]>; public static let recents: UIKey<[String]>; public static let saved: UIKey<[String]> /* "C/ts" */ }
extension UIKey where T == Bool { public static let sidebarVisible: UIKey<Bool> }
extension UIKey where T == Double { public static let sidebarWidth: UIKey<Double>; public static let threadWidth: UIKey<Double> }
extension UIKey where T == [String: Int] { public static let frequentEmoji: UIKey<[String: Int]> }
extension UIKey where T == ScrollAnchor { public static func scroll(_ channel: String) -> UIKey<ScrollAnchor> }
extension UIKey where T == String { public static func threadRead(_ channel: String, _ ts: String) -> UIKey<String> }
extension Store {
    func ui<T>(_ k: UIKey<T>) throws -> T?          // decode failure throws (never silently nil)
    func setUI<T>(_ k: UIKey<T>, _ v: T?) throws    // nil deletes
}
```

### 3.7 People, bots, groups, emoji (Store+People.swift)

```swift
public struct Person: Equatable {
    public var id: String; public var handle: String; public var displayName: String; public var realName: String
    public var isBot: Bool; public var botID: String?; public var deleted: Bool
    public var image48: String?; public var title: String?; public var tz: String?
    public var label: String { get }                 // displayName, else realName, else handle
}
public struct Bot: Equatable { public var id: String; public var name: String; public var userID: String?; public var image48: String? }
public struct UserGroup: Equatable { public var id: String; public var handle: String; public var name: String; public var users: [String] }
extension Store {
    func people() throws -> [Person]                 // non-deleted, in-memory after first read, invalidated by put(users:)
    func person(_ id: String) -> Person?             // memory only, no I/O on miss
    func bot(_ id: String) -> Bot?
    func usergroups() throws -> [UserGroup]          // [] + kv "usergroups.unavailable" when the API isn't there
    func myGroups() -> Set<String>
    func members(_ channel: String) throws -> Set<String>
    func customEmoji() throws -> [String: String]    // name → url | "alias:x"; [] + kv "emoji.unavailable"
}
```

### 3.8 Mentions (Mentions.swift)

```swift
public enum MentionTarget: Hashable, Codable { case user(String), group(String), channel(String), special(String) /* here|channel|everyone */ }
public struct MentionToken: Equatable { public var range: NSRange; public var target: MentionTarget; public var label: String }  // range in display text, UTF-16
public enum Mentions {
    /// display text + tokens → mrkdwn: & < > escaped outside tokens; tokens → <@U>, <!subteam^S>, <#C>, <!here>.
    public static func encode(_ display: String, tokens: [MentionToken]) -> String
    /// mrkdwn → display text + tokens, for edit-in-place and draft restore. Labels via `label`; nil keeps the raw id.
    public static func decode(_ mrkdwn: String, label: (MentionTarget) -> String?) -> (text: String, tokens: [MentionToken])
}
```

Tests: `decode(encode(x)) == x`. A plain typed `@foo` passes through unchanged. Editing keeps the ids.

### 3.9 Live (Live.swift)

```swift
public final class Live {
    public enum Status: Equatable { case connecting, live, reconnecting(after: Double, error: String), polling(reason: String), stopped }
    public init(store: Store, sync: Sync, appToken: String?)       // nil → polling("no app token")
    public var onStatus: ((Status) -> Void)?                         // main
    public var onChange: ((Set<String>) -> Void)?                    // main; same meaning as Sync.onChange
    public var onError: ((Error) -> Void)?                           // main
    public func start()
    public func stop()
    public func watch(channel: String?, thread: String?)             // poll targets (every ~10 s)
    public func setVisible(_ visible: Bool)                          // pauses polling when hidden
}
public enum EventApplier {
    /// Applies one events_api payload to the store; returns channels touched. Pure apart from the store.
    public static func apply(_ payload: Data, to store: Store) throws -> Set<String>
    public static func ack(for envelope: Data) throws -> Data         // {"envelope_id": …}
}
extension Config { public static func appToken(_ name: String, _ w: Workspace) -> String? }   // keychain "<ws>.app", or w.appToken for emulators
```

The events handled are listed in W1. Event ids are deduped through the `events` table. The backoff runs 1, 2, 4 … 60 s. Each apply must take under 2 ms, measured and logged when slower.

### 3.10 Mrkdwn (RENDER: Mrkdwn.swift)

```swift
public enum Mrkdwn {
    public enum MentionRef: Equatable { case user(String, label: String?), channel(String, label: String?), group(String, label: String?), special(String) }
    public indirect enum Inline: Equatable {
        case text(String), bold([Inline]), italic([Inline]), strike([Inline]), code(String)
        case mention(MentionRef), link(label: String?, url: String), emoji(String)   // "+1::skin-tone-2"
    }
    public enum Block: Equatable { case paragraph([Inline]), quote([Block]), code(String), list(ordered: Bool, items: [[Inline]]) }
    public static func parse(_ s: String) -> [Block]                                 // O(n), pure; names resolved at render
    public static func links(_ s: String) -> [(label: String?, url: String)]
    public static func plain(_ s: String, names: (String) -> String) -> String       // unchanged signature (Store fts)
    public static func runs(_ s: String, names: (String) -> String) -> [Run]         // kept until SHELL; then removed
}
```

### 3.11 Layout (RENDER: RelayCore/Render/ListLayout.swift)

```swift
public enum ListItem: Equatable {
    case message(index: Int, grouped: Bool)
    case day(Date)
    case unread                       // "New" divider, not focusable
    case threadReplies(count: Int)    // thread pane divider under the parent
}
public enum ListLayout {
    public static func items(_ ms: [Message], unreadAfter: String?, inThread: Bool, calendar: Calendar = .current) -> [ListItem]
    public static let groupWindow: TimeInterval = 300
}
public enum DayLabel { public static func string(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String }
public enum TimeLabel { public static func short(_ d: Date, now: Date = Date()) -> String; public static func gutter(_ d: Date) -> String }
public enum EmojiData { public static let byName: [String: String]; public static let names: [String] }  // generated
public enum EmojiSearch { public static func rank(_ q: String, frequent: [String: Int], custom: [String: String], limit: Int) -> [String] }
```

### 3.12 MessageList (RENDER: Relay/MessageList.swift), as SHELL calls it

```swift
struct MessageListContext {
    var me: String?
    var person: (String) -> Person?
    var name: (String) -> String                 // user id → label, raw id when unknown (A3)
    var channelName: (String) -> String?
    var groupHandle: (String) -> String?
    var customEmoji: [String: String]
    var draftThreads: Set<String>
    var threadUnread: (String) -> Bool           // thread ts → unread replies
    var writes: Bool                             // false: edit/delete buttons still show (G2)
}

enum ShowMode: Equatable {
    case keep                                     // live update: keep anchor or stay pinned at bottom
    case open(unreadAfter: String?, restore: ScrollAnchor?)   // unreads win over restore; else bottom
    case at(ts: String)                           // jump to message, cursor on it
}

struct LinkRef: Equatable { var url: URL; var label: String; var ts: String; var author: String }

struct MessageActions {
    var react: (Message) -> Void = { _ in log("unwired: react") }               // opens picker
    var toggleReaction: (Message, String) -> Void = { _, _ in log("unwired: toggleReaction") }
    var quickReactions: () -> [String] = { ["+1", "eyes", "white_check_mark"] }  // SHELL: top 3 of frequentEmoji
    var reply: (Message) -> Void = { _ in log("unwired: reply") }
    var copyLink: (Message) -> Void = { _ in log("unwired: copyLink") }
    var save: (Message) -> Void = { _ in log("unwired: save") }
    var edit: (Message) -> Void = { _ in log("unwired: edit") }                  // SHELL checks ownership, then list.beginEdit
    var saveEdit: (Message, String) -> Void = { _, _ in log("unwired: saveEdit") }  // mrkdwn from Mentions.encode
    var delete: (Message) -> Void = { _ in log("unwired: delete") }              // after the inline confirm
    var more: (Message) -> Void = { _ in log("unwired: more") }
    var retry: (Message) -> Void = { _ in log("unwired: retry") }                // failed echo
    var openThread: (Message) -> Void = { _ in log("unwired: openThread") }      // thread summary click
    var openUser: (String, NSRect) -> Void = { _, _ in log("unwired: openUser") }  // rect in list coords
    var openChannel: (String) -> Void = { _ in log("unwired: openChannel") }
    var openURL: (URL, Bool) -> Void = { _, _ in log("unwired: openURL") }        // Bool = background (⌘-click)
    var nearTop: () -> Void = {}
    var bottomVisible: () -> Void = {}            // fires when the newest row is visible ≥1 s with the window key
    var markRead: () -> Void = {}                 // jump pill "Mark as read"
}

final class MessageList: NSView {
    var context: MessageListContext
    var actions: MessageActions
    var inThread: Bool
    var focused: Bool
    var makeEditorTextView: () -> NSTextView      // SHELL swaps in ComposerTextView
    private(set) var messages: [Message]
    var selected: Int? { get }                    // index into messages (dividers excluded)
    var selectedMessage: Message? { get }
    var scrollAnchor: ScrollAnchor? { get }
    var visibleLinks: [LinkRef] { get }
    var isEditing: Bool { get }
    func show(_ ms: [Message], mode: ShowMode)
    func reload(ts: Set<String>)                  // re-render only these rows (avatar landed, user resolved)
    func select(_ i: Int); func step(_ d: Int); func selectLast(); func selectFirst()
    func scrollToBottom(); func jumpToUnread(); func jumpToNextMention()
    func beginEdit(ts: String) -> Bool            // false if not on screen
    func cancelEdit()
    func confirmDelete(ts: String)                // shows the inline strip; ↩/y → actions.delete, esc/n → cancel
    // compatibility until SHELL: names, onNearTop, onOpen, show(_:keep:cursor:), empty, table
}
```

Avatars (`Avatars.swift`): `final class Avatars { static let shared; var onLoad: ((String) -> Void)?; func layerContents(for id: String, name: String, url: String?, size: CGFloat) -> CGImage }` returns the initials placeholder at once and swaps in the photo later through `onLoad`. MessageList subscribes and calls `reload(ts:)` for that author's visible rows.

### 3.13 SHELL-only types (named now, so nobody else creates them)

- `Composer: NSView`, holding a `ComposerTextView: NSTextView`. Its API: `var key: (channel: String, thread: String?)`, `var onSend: (String) -> Void` (mrkdwn), `var onEditLast: () -> Void`, `var onReact: (String) -> Void`, `func restore(_ d: Draft?)`, `var draft: Draft { get }`, `var readOnly: Bool`.
- `RelayCore/Shell/Commands.swift`: `public struct Command { id, title, keys: [String], scope: Scope }` and `public enum Commands { static let all: [Command] }`.
- `RelayCore/Shell/Fuzzy.swift`: `public struct Fuzzy { init(_ haystack: [String]); func rank(_ q: String, limit: Int) -> [(Int, Int)] }`.
- `RelayCore/Shell/Sections.swift`: `public enum Sections { static func place(_ convs: [Conversation], sections: [SectionState], starred: [String], current: String?, drafts: Set<String>) -> [SidebarGroup] }`.

---

## 4. Acceptance per track (what the merge checks)

- **CORE**: `./test.sh` is green, with new tests for the migration v1→v2, the write gate with no request sent, every outbox transition, undo and too-late undo, the echo-before-reply case, reaction reconcile and rollback, draft persistence across reopening the Store, UIKey round-trips (including decode failure throwing), mentions encode and decode, the EventApplier fixtures (message, changed, deleted, reaction ±, *_marked) with acks, `firstUnread`, the query plan for unread counts, and the `perf` numbers on seed-bench. Against the emulator on :4013: `relayctl send` → `history` shows it; `edit`, `react` and `delete` round-trip; and with `writes:false`, each of those prints the error and leaves `outbox` empty.
- **RENDER**: `./test.sh` is green, with parser tests (one per construct, plus the timing test), ListLayout grouping, day and unread placement, DayLabel and TimeLabel, and EmojiSearch ranking. Headless snaps on :4023 show grouped rows with avatars, a day separator, the New divider, code blocks, quotes, lists, mention pills, reaction pills, the thread summary, the hover bar (via the script `hover`), and the inline editor. Scroll 2k rows with a log line for any `heightOfRow`+`viewFor` pass slower than 8 ms (there must be none), and the view count stays flat. Bench doesn't regress.
- **SHELL**: every P0 in product.md checked as it says, on :4003, plus bench.

## 5. Coordination

- Each track posts in this order: started, contract question, ready to merge. A contract change is a PR to this file, and the other track acks it before code depends on it.
- CORE pings @emulate with the gaps in product §16 on day one.
- Nobody pushes. The tech lead merges in the order in §1.
