# Relay product spec

The operator asked for "the slack UX: hovers, ux ui". The must-haves are
channels, threads, reactions, edit, delete, tagging bots and humans, local
sections, read/unread with scroll memory, code and markdown, local state
(drafts per thread), and a superhuman-style ⌘K that reaches everything.
Performance comes before anything else.

The visual reference is a screenshot of real Slack
(`~/.paw/spaces/paw/images/20261008-193055671-1-clipboard-2026-10-08-193055-502E5783.png`).
It shows a dark theme, a sidebar with sections (Starred, user-named sections
with emoji icons, Direct messages), bold unread rows, a pencil on rows that
hold drafts, a "Drafts & sent ✎14" count, a floating "↓ Unread mentions" pill,
messages grouped by author (avatar and name once, then bare follow-ups), link
pills, unfurl cards, reaction chips with a count and an add-reaction chip,
a hover toolbar on the right of the row (react, reply in thread, forward,
save, more), a "Today" day divider, and a composer with a placeholder
"Message <name>".

Priorities:
- **P0**: ships in the next build. Without it the app doesn't do the job.
- **P1**: needed for daily use. Lands right after P0.
- **P2**: polish, or anything blocked on the emulator.

Every acceptance criterion (AC) can be checked by a tester in one of these
ways:
- **test**: a swift-testing case in `./test.sh`
- **emu**: a headless run against your own emulator. Use
  `RELAY_HEADLESS=1 RELAY_SCRIPT="…; snap x.png; quit"` and Read the png, or
  `build/relayctl`.
- **bench**: `build/relayctl bench 8` on a release build

## 0. Ground rules

These apply to every feature.

- G1 P0. The 2027dev workspace stays `writes:false`. Every write method
  (`chat.*`, `reactions.add/remove`, `conversations.mark`, `conversations.open`)
  is refused by `Slack.call` with `writeBlocked`. The UI shows that error as a
  toast. It never fakes success. *test*: a write call against a
  `writes:false` client throws `writeBlocked`, and no HTTP request goes out
  (inject a URLProtocol that fails the test if it is hit).
- G2 P0. When writes are off, write keys (e, +, delete, the enter key in the
  composer) still open their UI. On commit they show
  `"<method> is a write and writes are off for this workspace"` and leave the
  outbox untouched. There is no local-only fake message.
- G3 P0. Every error from Slack, sqlite or the socket reaches both the toast
  and `relay.log`. Nothing is swallowed with `try?` on a path that changes
  data.
- G4 P0. Nothing that does network or sqlite work runs on the main thread,
  except the indexed reads that draw a frame (each one under 2 ms).
- G5 P0. Tokens are never printed, logged or written into the config for
  slack.com.

## 1. Channels and sidebar

- C1 P0. The sidebar lists every present conversation in this order:
  sections from config, then Starred, then Channels, then Direct messages.
  Each list is sorted unread first, then by most recent activity. Channels
  show `#name`. Private channels show a lock glyph. DMs show the person's
  display name. Group DMs (mpim) show the members' names joined with ", ".
  Bots show a bot badge. *emu*: a snap shows the seeded channels under
  "Channels" and DMs under "Direct messages".
- C2 P0. Selecting a row (click, ⌥↑/⌥↓, or ⌘K) opens the channel in under
  16 ms from cache. The header shows the name, plus the topic when there is
  one. *bench/test*: time `Store.messages(c, 200)` plus the table reload on a
  channel with 100k messages in the db. p95 is under 16 ms.
- C3 P0. Rows recycle. The sidebar `NSTableView` uses `makeView(withIdentifier:)`,
  and the view count stays flat when you scroll 1,000 conversations.
- C4 P1. Hovering a row highlights it. The selected row uses the accent fill
  (the screenshot's green bar).
- C5 P1. A "Find a conversation" field at the top of the sidebar (⌘T, or
  focus it with ⌘K). It does fuzzy filtering in place.
- C6 P2. Archived channels are hidden. Channels you left disappear on the next
  sync, but their messages stay searchable (this is the current
  `present=0` behaviour).

## 2. Sections (local)

- S1 P0. Sections live in `config.json` `sections: [{name, channels, collapsed?, emoji?}]`.
  A channel entry is a name or an id. A channel shows in exactly one section,
  and the first match wins. A channel listed in config but missing from the
  cache is skipped, and the log says so. *test*: placement rules, plus a
  duplicate channel landing in the first section.
- S2 P0. Starred is a built-in section, stored as `starred: [ids]`. ⌘K
  "Star #x" / "Unstar #x" toggle it. So does the shortcut ⌘⇧S on the current
  channel. The header shows a ★ when the channel is starred.
- S3 P0. Click a section header (or press ⌘K "Collapse section Y") to
  collapse or expand it. A collapsed section still shows its channels that
  have unreads or are selected, the way Slack does. Collapsed state survives
  a restart.
- S4 P1. These ⌘K commands exist:
  - "Move #x to section Y" (one row per section, and the current channel is
    the default x)
  - "New section…"
  - "Rename section Y…"
  - "Delete section Y" (its channels go back to Channels)
  - "Move section Y up/down"

  Each one writes the config atomically and redraws the sidebar without a
  sync. *test*: config round-trip after each operation.
- S5 P2. Drag a row to reorder it, or drag it between sections.

## 3. Messages: rendering

- M1 P0. Messages are grouped by author. A message from the same author
  within 5 minutes of the one before, with no day break and no thread
  parent, shows without the avatar or name. The first message of a group
  shows the name in bold, the time in grey, and an avatar placeholder (the
  user's initials on a colour hashed from the id). P2 adds images from
  `profile.image_48`.
- M2 P0. A day divider sits between days ("Today", "Yesterday", or
  "Tuesday, October 6").
- M3 P0. Rows are measured once per (message id, edited ts, width) and
  cached. Rows recycle. Scrolling 10k messages drops no frames
  (every frame is under 16 ms in an Instruments-free check: log any
  `heightOfRow` + `viewFor` pass slower than 8 ms).
- M4 P1. Hovering a row tints its background and shows a hover toolbar on the
  right, in this order: add reaction, reply in thread, edit (mine), delete
  (mine), copy link, more (⋯ opens message actions in ⌘K). Clicking each
  button does the same as its key. The toolbar is a single view moved
  between rows, not one per row.
- M5 P1. "(edited)" shows in grey after the text when the message has
  `edited`.
- M6 P1. Bot messages show the bot's name (`bot_profile.name`, or `username`,
  or `bots.info`) with an APP badge. A message with no user and no bot_id is
  an error in the log. It is never shown as "unknown".
- M7 P2. Unfurls: `attachments` with title, text and service_name show as a
  card. Files show as a filename chip that opens the permalink.
- M8 P2. System subtypes (`channel_join`, `channel_leave`, `channel_topic`)
  show as one grey line.

## 4. Markdown and code

Rendering is done by `Mrkdwn` → runs → `NSAttributedString`.

- K1 P0. These are rendered:
  - `*bold*`, `_italic_`, `~strike~`
  - `` `inline code` `` in a monospace font on a tinted background
  - fenced ```` ``` ```` blocks in a monospace block with a background and no
    reflow. A long line wraps inside the block. The block keeps line breaks.
  - `> quote` with a left bar, and `>>>` for the rest of the message
  - `•`/`-`/`1.` list lines with a hanging indent
  - `<url|label>` and bare urls as links. They open in the browser on
    ⌘-click, and on plain click on the link run.
  - `<@U>` as `@Display Name` (pill style, highlighted when it is me)
  - `<#C|name>` as `#name` (click opens it)
  - `<!here>`, `<!channel>` and `<!everyone>` as highlighted `@here`
  - `<!subteam^S|@handle>` as `@handle`
  - `&amp; &lt; &gt;` unescaped exactly once

  *test*: one case per construct. Formatting markers inside code are left
  alone (`` `*not bold*` ``). Words with underscores (`snake_case_name`) stay
  plain. There are no nested pathological cases with quadratic time: a 20 KB
  message parses in under 5 ms.
- K2 P0. Emoji shortcodes `:smile:` and `:+1::skin-tone-2:` show as Unicode
  from a bundled table, which `Emoji.swift` already starts. Custom emoji
  names that aren't in the table show as `:name:` in a subtle pill. Once
  `emoji.list` is cached (P1), they show the image, and aliases resolve.
- K3 P0. Composing: the composer sends exactly what the user typed, as
  mrkdwn text. The only rewrites are mention tokens (§8) and escaping
  `& < >` outside tokens. There is no rich-text editor. *test*: what you
  type → the `text` param.
- K4 P1. The composer shows light live styling of `*bold*`, `` `code` `` and
  fenced blocks while you type, with no layout jank. ⌘B, ⌘I, ⌘⇧X and ⌘⇧C wrap
  the selection in `*`, `_`, `~` or `` ` ``.
- K5 P1. In the composer, shift+enter inserts a newline. Inside an open
  ```` ``` ```` fence, enter inserts a newline and ⌘enter sends.

## 5. Threads

- T1 P0. A parent with `reply_count > 0` shows "N replies · last reply 3h ago"
  under it. P2 adds reply avatars. Clicking it, or pressing `r` on the
  cursor message, opens the thread pane on the right.
- T2 P0. The thread pane shows the parent, a "N replies" divider, the
  replies, and its own composer with the placeholder "Reply…". The first
  frame comes from cache, then `conversations.replies` fills it in. Esc
  closes it (when the composer is empty) and focus goes back to the list.
  Tab moves focus between the list and the thread.
- T3 P0. Replying sends `chat.postMessage` with `thread_ts` = parent ts and
  `reply_broadcast` off. There is no "also send to channel" checkbox, and
  the flag is never sent as true. *emu*: send a reply. The parent's
  `reply_count` goes up by 1 in the list without a refetch, and the reply
  does not show in the channel list.
- T4 P0. The open thread survives switching channels and back, and survives
  a restart (§10).
- T5 P1. A "Threads" view (⌘K "Threads", `g t`) lists threads I'm in that
  have new replies, newest first, from cache. Threads I'm in are threads I
  started, replied to, or am mentioned in.
- T6 P2. Broadcast replies from others (`subtype: thread_broadcast`) show in
  the channel with "replied to a thread: …".

## 6. Sending, with the outbox and undo

This copies Reply's Outbox.

- O1 P0. Enter in the composer puts the message in the outbox
  (`pending`) and it shows at once in the list, in grey, with a "Sending… z
  to undo" hint. After 5 s (configurable as `undoSeconds`) it is posted.
  When it is posted the row becomes the server message (matched by
  `client_msg_id`, or by the returned ts), and nothing flickers or
  duplicates. *test*: the outbox state machine pending → sending → sent,
  pending → cancelled, and sending → failed (with the error).
- O2 P0. `z` (or ⌘Z when the composer is empty) inside the window cancels
  the newest pending item and puts its text back in the composer. After the
  window, `z` shows "Too late to undo, already sent". It does not start a
  delete.
- O3 P0. A failed send keeps the row in red with the error, and `↩` on it
  retries. Quitting while items are pending writes them to sqlite. On the
  next launch they show as "not sent" and are never auto-sent.
- O4 P0. Edits (§7) and deletes (§7) go through the same outbox with the same
  undo window. Reactions are immediate (optimistic), and a failure is rolled
  back with a toast.
- O5 P1. Sending in a DM I don't have open yet calls `conversations.open`
  first (§9).

## 7. Edit and delete own message

- E1 P0. `e` on the cursor message, or the pencil in the hover toolbar, edits
  it. `↑` in an empty composer edits my newest message in the current
  list or thread. This only works on my own messages: a message from
  someone else toasts "You can only edit your own messages". *test*: the
  ownership check uses `store.me`.
- E2 P0. Edit happens in place. The row turns into an inline text view with
  the raw text, where mention tokens show as `@name` and are re-encoded on
  save. Enter saves (it goes to the outbox as `chat.update`, and the row
  shows the new text plus "(edited)" right away). Esc cancels and restores
  the row with no request. Shift+enter adds a newline.
- E3 P0. `z` within the undo window after saving restores the old text and
  sends nothing. *emu*: edit, wait 6 s, then `conversations.history` shows
  the new text and `edited`.
- E4 P0. Deleting, with `⌫`/`d` on my cursor message or the trash in the
  hover toolbar, shows an inline confirm strip on the row, not a modal:
  "Delete this message? ↩ delete · esc cancel". Enter (or `y`) confirms and
  esc (or `n`) cancels. After confirming, the row collapses with "Deleted ·
  z to undo" for the window, then `chat.delete` runs. Deleting a parent
  that has replies says "…and keep N replies" (that is what Slack does).
- E5 P0. Server-side errors such as `cant_update_message`, `edit_window_closed`
  and `message_not_found` restore the original row and toast the error code
  word for word.
- E6 P1. Edits and deletes from others, arriving live (§12), update the row
  in place. A deleted message is removed from the fts index as well
  (`Store.delete` already does this).

## 8. Mentions: humans, bots, user groups

- A1 P0. Typing `@` in either composer opens an autocomplete popover
  anchored at the caret. It lists people (display name, real name, @handle),
  bots (with an APP badge), user groups (`@handle`, name, member count), then
  `@here`, `@channel` and `@everyone`. Members of the current channel come
  first. Matching is prefix-first, then fuzzy. ↑/↓/ctrl-n/ctrl-p move, tab or
  enter inserts, esc closes. Results come from the in-memory cache in under
  2 ms for 5k users.
- A2 P0. When you insert one, the composer shows the `@Display Name` token
  as an atomic pill: backspace removes the whole token. On send it is
  encoded as `<@U123>` for a person or bot user, `<!subteam^S123>` for a
  group, and `<!here>`/`<!channel>`/`<!everyone>`. Text you type as plain
  `@foo` with no pick is sent as is, because Slack resolves nothing in that
  case. *test*: encode and decode round-trip, and editing a message with
  mentions keeps its ids.
- A3 P0. Rendering resolves `<@U>` through the users cache, including bots.
  A missing user triggers a background `users.info`, and the row redraws when
  it lands. Until then the row shows the raw id, so nothing is fabricated.
  `<!subteam^S>` with no label resolves through `usergroups.list`.
- A4 P1. Messages that mention me (`<@me>`, or a group I'm in, or
  here/channel) are highlighted with a yellow tint. They count as mentions
  in sidebar badges (the red number pill).
- A5 P1. `#` autocompletes channels the same way and encodes `<#C123>`.
- A6 P1. Sync caches `usergroups.list` (with `include_users=true`) and
  `bots.info` for bot ids seen in messages. They refresh daily.

## 9. Reactions

- R1 P0. Reactions show under a message as chips: emoji, then count. A chip
  is highlighted (accent border and fill) when `users` contains me. Hovering
  a chip shows "Mira, Tomás and 3 others reacted with :eyes:". A trailing
  "add reaction" chip appears on hover.
- R2 P0. `+` on the cursor message (or the hover button or chip) opens the
  emoji picker. It is a search field over shortcodes, with standard ones
  plus custom ones from `emoji.list` when cached, and a "frequently used"
  row first (kept locally). Typing filters by prefix and contains. Enter
  picks the top hit, ↑/↓ move, esc closes. *test*: picker ranking.
- R3 P0. Picking an emoji I haven't reacted with calls `reactions.add` and
  bumps the chip right away. Picking one I have, or clicking my highlighted
  chip, calls `reactions.remove`. `already_reacted` or `no_reaction` from the
  server brings the local state in line with the server and does not toast.
  Any other error rolls back and toasts. *emu*: add then remove, and
  `reactions.get` matches at each step.
- R4 P1. Pressing `+` and then typing `:shortcode` inline in the composer
  as the whole message (`+:eyes:`) reacts to the newest message, as Slack
  does.
- R5 P1. Skin tones (`::skin-tone-N:`) render and can be picked.

## 10. Read/unread and scroll

- U1 P0. A sidebar row is bold when it has unread top-level messages from
  others past `max(last_read, seen)`. That is `Store.conversations` as it is
  now. Rows with mentions show a red count pill. DMs and group DMs always
  show the count. Channels show only bold, unless there are mentions.
- U2 P0. Opening a channel draws a "New messages" divider (a red line with
  a label) above the first message after `last_read`. It stays until you
  leave the channel, even though reading moves the cursor.
- U3 P0. Viewing marks it read. When the newest message has been visible for
  ~1 s with the window focused, the read cursor moves to it. With writes on,
  `conversations.mark` is called (debounced, at most 1 per channel per 3 s).
  With writes off, `Store.markSeen` is called. Both update the sidebar at
  once. *test*: `markSeen` makes unread 0, and `last_read` later than seen
  wins.
- U4 P0. Opening a channel that has unreads lands on the first unread (the
  divider near the top of the view). With no unreads it lands at the bottom,
  or at the remembered scroll position (U6). A floating pill "↑ N new
  messages" / "↓ Jump to recent" appears when the unread or newest message
  is off screen. Clicking it or pressing `shift+esc`/`g n` jumps there.
- U5 P0. Navigation keys:
  - `g u`: open the next conversation with unreads (mentions first)
  - ⌥⇧↓ / ⌥⇧↑: next or previous unread conversation in sidebar order
  - ⌥↓ / ⌥↑: next or previous conversation (exists)
  - ⌘K "Mark all read": with writes on, `conversations.mark` for each
    conversation, rate-limited. With writes off it uses local seen.
  - `esc` in a channel with no overlay: mark the channel read
  - ⇧esc: mark all read, after an inline confirm strip
- U6 P0. Scroll position is remembered per channel: the anchor message ts
  plus its pixel offset. It is restored when you come back (unless there
  are new unreads, which win). It survives a restart. *emu*: scroll up in
  #general, switch, switch back, then snap. The same top message is visible.
- U7 P1. Older messages load as you approach the top (`loadOlder`, exists)
  without jumping the scroll (anchor-preserving insert).
- U8 P1. Threads have their own unread state. Replies after my last view
  of the thread mark the thread row in "Threads" (T5).

## 11. Local state (survives restart)

This is stored per workspace, in the sqlite `kv` table or a dedicated
`drafts` table. It is not stored in UserDefaults.

- L1 P0. Drafts are kept per channel and per thread (key `channel` or
  `channel/thread_ts`). They are saved 300 ms after the last keystroke and on
  switching or quitting, and cleared on send. Mention pills survive as
  tokens. *test*: save, reopen the Store, and the draft is there.
- L2 P0. A sidebar row whose channel, or one of whose threads, has a draft
  shows a ✎ pencil and is never hidden by a collapsed section. ⌘K "Drafts"
  lists all drafts and opens each one at its composer.
- L3 P0. Restored on launch, before any network, so it is in the first
  frame: the selected channel, the open thread, per-channel scroll anchors
  (U6), collapsed sections (S3), sidebar visibility, and the thread pane
  width.
- L4 P1. Emoji "frequently used" and ⌘K recents (the last 20 picks rank first
  on an empty query).

## 12. Live updates

- W1 P0 (code), P2 (emulator test). Socket Mode works like this:
  1. If the keychain has `relay`/`<ws>.app` (an xapp token), call
     `apps.connections.open` with it as bearer. Note that this is the app
     token, not the user token.
  2. Open the returned wss URL with `URLSessionWebSocketTask`.
  3. Handle `hello`.
  4. For each `events_api` envelope, ack with `{"envelope_id": …}` within
     3 s, then apply the event to the store off the main thread.
  5. On `disconnect` (`refresh_requested`, `link_disabled`), reconnect with
     a fresh URL. On socket error, reconnect with backoff (1, 2, 4 … 60 s).

  Events to handle: `message` (and its subtypes `message_changed`,
  `message_deleted`, `thread_broadcast`), `reaction_added`/`reaction_removed`,
  `channel_marked`/`im_marked`/`group_marked`/`mpim_marked`, `member_joined_channel`,
  `user_change`, `emoji_changed`, `subteam_updated`. Event ids are deduped.
  The connection state shows in the sidebar status line ("live",
  "reconnecting…"). *test*: decode and apply each envelope fixture against
  an in-memory Store, and the ack is built for each.
- W2 P0. When there is no app token, the app falls back to a refresh on
  window focus (exists) plus a poll of the open channel (and open thread)
  every ~10 s with `conversations.history oldest=synced`. The poll pauses
  when the window is hidden. The status line reads "polling (no app token)".
  The app never invents an xapp token.
- W3 P1. The manifest (`dev/slack-manifest.json`) adds `user_events`
  `message.*` (already there), `reaction_*`, `channel_marked`, `im_marked`,
  `group_marked`, `mpim_marked`, `user_change`, `emoji_changed`,
  `subteam_updated`. `dev/store-token.sh` documents storing the
  `connections:write` app token as `<ws>.app`.

## 13. ⌘K: everything

One palette. It fuzzy-ranks over every source in one list. Each row shows a
kind icon, a title, detail, and the shortcut right-aligned. An empty query
shows recents, then context actions for the cursor message, then commands.
Prefixes narrow the list: `#` channels, `@` people, `>` commands,
`/` messages, `:` emoji react.

- K-1 P0. Conversations: every present conversation, with unread and mention
  counts. Enter opens it.
- K-2 P0. People and bots: every non-deleted user. Enter opens their DM. If
  no im exists, it calls `conversations.open users=U` (a write, so it is
  blocked when writes are off, with that toast). Then it caches the im and
  opens it.
- K-3 P0. Commands. Every app command is here with its shortcut shown. This
  list is the source of truth for the key map, and a test asserts that every
  key handler has a command entry:
  - Jump to unreads `g u`
  - Next/previous unread `⌥⇧↓/↑`
  - Mark channel read `esc`
  - Mark all read `⇧esc`
  - Search messages `/`
  - Refresh `⌘R`
  - Toggle sidebar `⌘⇧D`
  - Toggle thread pane
  - Threads `g t`
  - Drafts
  - Star/unstar channel `⌘⇧S`
  - Move #x to section Y, New/Rename/Delete section, Collapse/expand section
  - Open in Slack (web) `⌘⇧O`: `https://<team domain>.slack.com/archives/<C>[/p<ts>]`
  - Copy link to channel or message
  - Switch to workspace <name>
  - Toggles: compact mode, show seconds in timestamps, undo window 5/10 s,
    live/poll status, open log file, reveal database in Finder
  - Quit

  A toggle writes the config and shows its current state ("✓").
- K-4 P0. Links in view: every URL in the visible messages and open thread,
  shown with its label and host. Enter opens it in the default browser.
  ⌘enter copies it. `<#C>` links open in-app.
- K-5 P0. Message actions on the cursor message: Reply in thread `r`,
  React `+`, Edit `e` (mine), Delete `⌫` (mine), Copy text, Copy link,
  Open in Slack, Mark unread from here (moves the local seen back; with
  writes on, `conversations.mark` to the previous ts).
- K-6 P0. Search: typing a query adds a "Search messages for "…"" row at the
  bottom, and local fts hits appear inline (up to 5). Enter on the row opens
  the full search overlay (exists, with remote search.messages).
- K-7 P0. Speed: the palette opens in under 30 ms, and each keystroke
  re-ranks 10k items in under 8 ms off a precomputed lowercased haystack.
  Ranking is prefix-of-word first, then subsequence, then recency. *test*:
  ranking fixtures, and a timing test over 10k items.
- K-8 P1. Emoji: `:sm` lists matching emoji. Enter reacts on the cursor
  message.

## 14. Keyboard map (P0, single source in the command list)

| key | action |
| --- | --- |
| j / k, ↓ / ↑ | cursor message |
| g g / G | top / bottom |
| r | open thread / reply |
| e, ↑ in empty composer | edit mine |
| ⌫ / d | delete mine (inline confirm) |
| + | react |
| z | undo last send, edit or delete within the window |
| i or ↩ | focus composer |
| esc | close overlay or thread, cancel edit, else mark read |
| tab | list ↔ thread |
| g u | next unread conversation |
| ⌥⇧↑/↓ | prev/next unread conversation |
| ⌥↑/↓ | prev/next conversation |
| / | search |
| ⌘K | everything |
| ⌘R | refresh |

Single-letter keys work only when no text field has focus.

## 15. Performance budgets (P0, regressions block a merge)

| what | budget | how to check |
| --- | --- | --- |
| first frame, warm cache, normal load | < 250 ms process start to first committed frame, p50 over 8 runs (aim 150) | `build/relayctl bench 8`, release |
| channel switch from cache | < 16 ms to a drawn frame | timing log `switch <id> <ms>` |
| typing latency in composer | < 8 ms per keystroke incl. autocomplete and draft save scheduling | timing log, 5k users |
| ⌘K open / keystroke | < 30 ms / < 8 ms | timing test |
| 100k-message cache | db with 100k messages across 200 channels: first frame and channel switch stay within the budgets above; `Store.conversations()` < 10 ms | seeded fixture via `relayctl seed-bench` (to add) |
| memory | < 150 MB RSS after opening 20 channels | `ps -o rss` |
| socket event apply | < 2 ms per message event, off main | timing log |

The unread count subqueries in `Store.conversations()` must be backed by
`messages(channel, ts)`. Add an index if the 100k fixture shows a scan.
Never call a per-row `name(of:)` that misses the cache in a hot loop.

## 16. Emulator gaps (ask @emulate)

These are checked against `~/.paw/repos/vercel-labs/emulate/packages/@emulators/slack/src`.
- `usergroups.list` (and `usergroups.users.list`): missing. These block A1,
  A3 and A6 tests. Seeds need `usergroups:` in emulate.yaml.
- `emoji.list`: missing. This blocks custom-emoji rendering and picker tests
  (K2, R2). The seed needs `emoji: {name: url | alias:x}`.
- Socket Mode: missing. We need `apps.connections.open` accepting an
  `xapp-` token and returning a ws URL. The ws must send `hello` and
  `events_api` envelopes for message, message_changed, message_deleted,
  reaction_added, reaction_removed and *_marked. It must require acks, and
  support a `disconnect` frame on demand (for the reconnect test).
- `reply_broadcast` on `chat.postMessage`: not handled (it is ignored). We
  only need it ignored or false, but `subtype: thread_broadcast` for T6 needs
  it.
- `bots.info` exists. Messages posted by a bot should carry `bot_id` and
  `bot_profile` the way Slack does. Please confirm the seed can define bots
  (`bots:` in yaml) that post.
- `users.conversations` should return `last_read` per conversation for user
  tokens (real Slack doesn't, so we call `conversations.info`, which the
  emulator already handles). Low priority. Just confirm `conversations.info`
  `last_read` reflects `conversations.mark`.
- `chat.update`/`chat.delete` exist and enforce authorship
  (`cant_update_message`/`cant_delete_message`). An optional
  `edit_window_closed` mode would let us test E5.
- `search.messages` exists now (CLAUDE.md is out of date on this).
  `in:`/`from:` modifiers are supported.
- A user `profile.image_48` in the seed, for avatars (P2).
