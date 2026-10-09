# Relay visual spec

The target is the reference screenshot of real Slack (dark, custom olive sidebar
theme), adapted to AppKit and to a keyboard-first app. Every number here is in
points at 1x. Slack's web UI is drawn in Lato at 15px; SF Pro at 14pt has the
same optical size, so Slack px values are converted with a ~0.93 factor and rounded.

Rendering rules that hold everywhere:

- Every view is layer-backed (`wantsLayer = true`, `layerContentsRedrawPolicy = .onSetNeedsDisplay`).
- Lists are view-based `NSTableView`s whose cells **and row views** come from
  `makeView(withIdentifier:)`. Today `MessageList.rowViewForRow` and
  `Sidebar.viewFor` build new views for every row: fix both first.
- Heights are measured off the main thread or once per width, cached by
  `(ts, editedTS, width)`, and never re-measured inside `layout()` for rows that didn't change.
- Hover state lives in one `NSTrackingArea` on the table (`.mouseMoved`,
  `.activeInKeyWindow`, `.inVisibleRect`); the hovered row index is a single
  property. One shared hover action bar is moved between rows. No tracking area per row.
- Colors are `NSColor(name:dynamicProvider:)` tokens in `Palette`, so
  appearance changes don't rebuild anything. `cgColor` is re-read in
  `viewDidChangeEffectiveAppearance` / `updateLayer`.
- Icons are SF Symbols (`NSImage(systemSymbolName:)`), cached per
  (name, pointSize, weight) in a static dictionary.

---

## 1. Tokens

### 1.1 Color (dark / light)

| token | dark | light | use |
| --- | --- | --- | --- |
| `bg` | `#1A1D21` | `#FFFFFF` | message list, header, thread pane |
| `bgHover` | `#222529` | `#F8F8F8` | hovered message row, composer fill |
| `bgRaised` | `#222529` | `#FFFFFF` | hover bar, popups, palette card, link card |
| `border` | `#35373B` | `#DDDDDD` | header divider, card borders, composer border (idle) |
| `borderStrong` | `#565856` | `#868686` | composer border (focused), hover bar border |
| `text` | `#D1D2D3` | `#1D1C1D` | body |
| `textStrong` | `#F8F8F8` | `#1D1C1D` | author names, channel title, unread sidebar rows |
| `textMuted` | `#ABABAD` | `#616061` | timestamps, placeholders, (edited), tab labels |
| `textFaint` | `#7C7E80` | `#9A9A9A` | hover time on grouped rows, footnotes |
| `link` | `#1D9BD1` | `#1264A3` | links |
| `linkChipBg` | `#1D9BD1` @ 12% | `#1264A3` @ 8% | link capsule behind bare URLs (screenshot) |
| `mention` | `#1D9BD1` @ 18% bg, `#5DBDEB` fg | `#1D9BD1` @ 10% bg, `#1264A3` fg | @someone else, #channel |
| `mentionMe` | `#ECB22E` @ 22% bg, `#F2C744` fg | `#F2C744` @ 30% bg, `#1D1C1D` fg | @me, @here, @channel |
| `mentionMeRow` | `#ECB22E` @ 6% | `#FEF7E0` | whole row background when a message mentions me |
| `codeBg` | `#2C2D30` | `#F6F6F6` | inline code and code block fill |
| `codeBorder` | `#3B3D41` | `#DDDDDD` | inline code and code block border |
| `codeInline` | `#E8912D` | `#C01343` | inline code text (Slack's orange/red) |
| `quoteBar` | `#5E6064` | `#DDDDDD` | blockquote bar |
| `unreadRed` | `#E01E5A` | `#E01E5A` | "New messages" divider, toast error |
| `reactBg` | `#2C2D30` | `#F2F2F2` | reaction pill fill |
| `reactBorder` | `#2C2D30` | `#F2F2F2` | reaction pill border, same as fill when not mine |
| `reactMineBg` | `#1D9BD1` @ 22% (≈`#18435A`) | `#E8F5FA` | reaction pill when I reacted |
| `reactMineBorder` | `#1D9BD1` | `#1D9BD1` | |
| `cursor` | `#1D9BD1` | `#1264A3` | keyboard cursor bar |
| `cursorTint` | `#1D9BD1` @ 10% | `#1264A3` @ 7% | keyboard cursor row fill |
| `accentPill` | `#BE79EC` | `#7C3AED` | floating "Unread mentions" pill (screenshot purple) |
| `success` | `#2BAC76` | `#007A5A` | toasts ("Sent"), online dot |

Sidebar theme (the screenshot's olive theme is the dark default; light uses Slack's light aubergine-free neutral):

| token | dark | light |
| --- | --- | --- |
| `sbBg` | `#161C0E` | `#F8F8F8` |
| `sbTopBar` | `#252E07` | `#ECECEC` |
| `sbText` | `#B5C380` | `#616061` |
| `sbTextUnread` | `#FFFFFF` | `#1D1C1D` |
| `sbHeader` | `#B5C380` | `#616061` |
| `sbHover` | `#FFFFFF` @ 6% | `#000000` @ 5% |
| `sbSelectedBg` | `#BAFCC1` | `#1164A3` |
| `sbSelectedText` | `#0E1B05` | `#FFFFFF` |
| `sbSeparator` | `#22271A` | `#E2E2E2` |
| `sbField` | `#FFFFFF` @ 8% bg, `#3C432C` border | `#FFFFFF` bg, `#DDDDDD` border |
| `sbFieldFocus` | border `#9ACCE8` 2pt | border `#1D9BD1` 2pt |
| `sbBadge` | `#BE79EC` bg, `#FFFFFF` fg | `#E01E5A` bg, `#FFFFFF` fg |
| `paneDivider` | `#3C432C` | `#DDDDDD` |

### 1.2 Type (SF Pro, system font)

| style | size / weight | line height | use |
| --- | --- | --- | --- |
| `title` | 17 bold | 22 | channel name in header, workspace name |
| `name` | 14 semibold (`.bold` looks too heavy on SF) | 20 | author |
| `body` | 14 regular | 20 (lineSpacing 2.5 → min/max line height 20) | message text |
| `meta` | 11.5 regular, monospacedDigit | 16 | time next to name |
| `hoverTime` | 10.5 regular, monospacedDigit | 20 | gutter time on grouped rows |
| `sbRow` | 14 regular, 14 semibold when unread | 18 | sidebar rows |
| `sbHeader` | 14 medium | 18 | sidebar section headers (Slack doesn't uppercase) |
| `small` | 12 regular | 16 | tabs, reactions count, "3 replies", divider label |
| `mono` | `NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)` | 18 | inline code, code blocks |
| `badge` | 11 bold, monospacedDigit | 16 | mention badge |

Only these styles exist. Make them static `NSFont`/attribute dictionaries in a `Type` enum; never build a font per row.

### 1.3 Spacing and radii

- Base grid 4pt. Gutter inside the message pane: 20 left, 20 right.
- Radii: rows and pills 6, cards and composer 8, palette 12, avatars 6 (36pt) / 4 (20pt) / 3 (16pt).
- Shadows only on floating things (hover bar, popups, palette, floating pills, toasts):
  `shadowColor black`, `opacity 0.25 dark / 0.12 light`, `radius 8`, `offset (0, -2)`. Set
  `layer.shadowPath` explicitly, so no offscreen pass happens.

---

## 2. Window chrome

- Window: `.titled .closable .miniaturizable .resizable .fullSizeContentView`,
  transparent titlebar, hidden title. Default 1180×760, min 760×420.
- Top bar (titlebar area) is 38 high and spans the whole window with `sbTopBar` fill.
  The traffic lights sit at the default position (x 12). The bar holds:
  - back/forward chevrons, at x = sidebar width - 70: `chevron.left`, `chevron.right`, 13pt medium, `sbText`, 28×28 hit area. They walk a local history of opened conversations and threads (⌘[ / ⌘]).
  - a centered search pill, 26 high, radius 6, max width 640, min 280, fill `#FFFFFF` @ 18% (dark) / `#FFFFFF` (light),
    with `magnifyingglass` at 12pt and the placeholder "Search 2027.dev" in 13 `textMuted`. Clicking it or pressing `/` opens the search overlay. It's a button, not a field, so nothing is first responder in the chrome.
  - Drag the window from any empty part of the bar (`mouseDownCanMoveWindow`).
- No workspace rail (Slack's left icon column). One workspace, which ⌘K switches. The 64pt is given back to the sidebar.
- Panes under the bar: sidebar | 1pt `paneDivider` | message pane | 1pt `border` | thread pane (when open).
  The sidebar is 260 wide by default, resizable 200 to 360 with a split view, and the width is autosaved.
  The thread pane is 380 wide by default, 320 to 560.

## 3. Sidebar

Everything in one `NSTableView` (rows of different kinds, each kind with its own reuse identifier), fill `sbBg`, inset 8 left/right (so the selected fill floats with 8pt margins, as in the screenshot).

### 3.1 Workspace header (not a table row; fixed above the table)

- 52 high. Workspace name in `title` (17 bold) `sbTextUnread`, followed by `chevron.down` 10pt semibold at 6pt spacing. Clicking it opens ⌘K prefilled with "workspace ".
- Right side: `square.and.pencil` 16pt (new message, which opens ⌘K on "people"), 28×28 hit area, at 12 from the right. Hover: a 28×28 radius 6 `sbHover` square behind it.
- The sync status (now in the footer) moves into this header as an 11pt `sbText` line under the name only while syncing or after an error ("Syncing 3 of 40…", "Offline: <error>"). Otherwise it's hidden and the header is 52.

### 3.2 Find field

- 30 high, x inset 8, 6 below the header. Radius 6. Fill and border `sbField`, focus `sbFieldFocus` (2pt, inner).
- Leading `text.magnifyingglass` 13pt `sbText` at x 8; placeholder "Find a conversation…" 13 `sbText` @ 70%.
- Typing filters the sidebar in place (fuzzy, prefix-weighted, the same matcher as ⌘K). ↑/↓ move, ↩ opens, esc clears and returns focus to the list. Shortcut: ⌘⇧K, or `t` when nothing is editing.

### 3.3 Top items

Rows of 28 (text centered), icon at x 12 (16pt box, 14pt symbol, `sbText`), label at x 36 in `sbRow`:

| label | symbol | action |
| --- | --- | --- |
| Threads | `bubble.left.and.text.bubble.right` | followed threads with new replies (local) |
| Mentions | `at` | messages that mention me, from the cache |
| Drafts | `paperplane` | conversations and threads with a saved draft. Right: `pencil` 11pt + count in `small` |

Then 8 empty, a 1pt `sbSeparator` line inset 12, and 8 empty.

### 3.4 Section headers

- 28 high, with 10 above each one except the first (an 8pt spacer row so heights stay uniform per kind).
- Disclosure chevron at x 12: `chevron.down` (open) / `chevron.right` (collapsed), 9pt bold `sbHeader`. It rotates over 0.15s with a `CATransform3D` on the image layer, not a re-layout.
- Optional section emoji/symbol at x 26 (16pt box): local config `icon` (an SF Symbol name or an emoji). The screenshot shows `star` for Starred, 💡 for todo and ✅ for Paid customers.
- Label at x 46 in `sbHeader`.
- On hover, show `ellipsis` 12pt at the right (rename, delete section, sort A→Z / by recent: a local menu).
- Click or `space` on the header toggles collapse. Collapsed sections still show their **unread** rows (Slack's behavior), so nothing unread disappears.
- Collapse state, order and membership are local: saved in the store's kv table (`sidebar.sections`), not in config, so they change without a restart. Config `sections` seed them on first run.
- Default order: Starred (local), then config sections, then Channels, then Direct messages. The current "Unread" section goes away: unread is shown by weight and badge, and `g u` / "Unread mentions" pill does the jumping.

### 3.5 Conversation rows

- 28 high. Selected and hover fills are inset 8 left/right, with radius 6.
- Leading glyph box at x 26, 16×16:
  - public channel: `number` 13pt regular
  - private channel: `lock.fill` 11pt
  - DM: the person's avatar, 16×16, radius 3 (4 for bots, as Slack does), with a presence dot of 7pt at the bottom right, ring 1.5pt in `sbBg` (green `success` when active, hollow `sbText` border when away). Self DM: avatar + label "you" in `sbText` @ 70% after the name (screenshot).
  - group DM: a count glyph (`person.2.fill` 11pt).
  - bot DM: the bot avatar, radius 4.
- Label at x 48 in `sbRow`, truncating tail.
- States:
  - read: `sbText`, regular.
  - unread: `sbTextUnread`, semibold (screenshot: `# ext-browseruse-2027dev`). The glyph also goes `sbTextUnread`.
  - muted: `sbText` @ 50%, never bold.
  - selected: fill `sbSelectedBg`, text and glyph `sbSelectedText`, weight unchanged.
  - hover: `sbHover` fill.
- Trailing, right aligned at 12 from the inset edge, in this priority:
  1. mention badge: a pill 18 high, min width 18, horizontal padding 6, radius 9, `sbBadge`, the number in `badge` style. For DMs every unread counts as a mention.
  2. draft: `pencil` 11pt `sbText` (screenshot) when the conversation or any of its threads has a draft.
  3. nothing.
- The keyboard cursor in the sidebar is the selection itself (the sidebar follows the open conversation). When the sidebar has focus (after ⌘⇧K or Tab), add a 2pt `cursor` focus ring inside the selected fill.

### 3.6 Floating pill

When unread or mention rows are scrolled out of the sidebar's view, show a pill at the bottom (or top), centered, 16 above the edge: 28 high, radius 14, `accentPill` fill, white 12 semibold text "↓ Unread mentions" (`arrow.down` 10pt bold) or "↓ More unreads" (no mentions). Click scrolls the first one into view. It's a sibling view over the scroll view, never a table row.

## 4. Channel header

- 49 high (Slack's 49), `bg` fill, 1pt `border` bottom line.
- Left at x 20: star toggle `star` / `star.fill` 14pt (fill `#ECB22E` when starred; starring is local and moves the row to Starred). Then 8, glyph (`number` 15pt semibold `textStrong`, or the 20pt avatar radius 4 for DMs), 6, name in `title` `textStrong`, then `chevron.down` 10pt `textMuted`. Clicking the name opens a details popover (topic, members count, Copy link, Open in Slack).
- Topic, if any, after a 12pt gap in 13 `textMuted`, truncating, on the same baseline.
- Right at 16 from the edge: `magnifyingglass` (search in channel, opens `/` scoped with `in:#name`), `ellipsis` (vertical: `ellipsis` rotated, or `ellipsis.vertical` on macOS 15+). 16pt, `textMuted`, 28×28 hover square radius 6 `bgHover`.
- Tabs row (optional, milestone 3): 36 high under the title, tabs at x 20 with 18 spacing: "Messages" (`bubble.left.fill`), "Files" (`doc.on.doc`), "Pins" (`pin`). 13 medium `textMuted`, the active tab in `textStrong` with a 2pt underline radius 1 in `textStrong`, flush with the header's bottom border. Ship without tabs first. The header is then exactly 49.

## 5. Message list

### 5.1 Row anatomy (first message of a group)

```
| 20 | avatar 36 | 8 | name  time            | 20 |
|    |           |   | body …                |    |
|    |           |   | [reactions]           |    |
|    |           |   | [n replies · last]    |    |
```

- Padding top 8, bottom 8. The content column starts at x 64 (20 + 36 + 8).
- Avatar: 36×36, radius 6 (Slack's rounded square), `CALayer.contents` set from a decoded `CGImage`
  cached in memory (an LRU of 512) and on disk under `RELAY_HOME/avatars/<user>-<hash>.png`. Fetched off main. Before it arrives,
  draw the initials on a color hashed from the user id (one of 8 muted tones), 15 semibold white. Bots get radius 8 and an `APP` tag after the name: 9 bold `textMuted` on `codeBg`, padding 2/4, radius 3.
- Name: `name` `textStrong`, baseline aligned with the time. Clicking the name or avatar opens the profile popover (name, title, local time, "Message", "Copy user ID").
- Time: `meta` `textMuted`, 6 after the name. "4:52 PM" today, "Yesterday at 4:52 PM", otherwise "Oct 3rd at 4:52 PM", with the full date in a tooltip.
- Body starts 2 under the name line, in `body` `text`.

### 5.2 Grouping

- A message joins the previous group when: the same user (and the same bot profile for bots), within **5 minutes** of the previous message,
  neither one is a thread broadcast or a system subtype, no date separator or "New messages" divider falls between them, and the previous message has no visible thread summary.
- Grouped rows draw no avatar and no name. Padding top 2, bottom 2 (the group's last row keeps bottom 8). The body starts at x 64.
- On hover (and under the keyboard cursor), the grouped row shows its time in the avatar gutter: `hoverTime` `textFaint`, right aligned to x 56, on the first line's baseline. "4:52" only, no AM/PM, as Slack does.
- Grouping is computed once per `show()`, in the same pass that builds the attributed strings, as a `[Bool]` parallel to `messages`. The first visible row after a load-more prepend gets re-checked.

### 5.3 Hover and cursor (two different things)

- **Hover**: the row fill becomes `bgHover`. No border. It follows the mouse and nothing else.
- **Keyboard cursor** (j/k): a 3pt `cursor` bar flush left (x 0, full row height) plus `cursorTint` fill. When both apply, the tint is drawn over the hover fill, so the cursor is always visible.
  When the pane isn't focused, the bar becomes `textFaint` and the tint 4%. Keep the current `MessageRow.drawSelection` approach, with new colors.
- The cursor never follows the mouse. A click sets the cursor (the current behavior). Scrolling never moves the cursor. If the cursor scrolls out of view, `j`/`k` first bring it back, then move.
- When a row is hovered **and** another row has the cursor, the hover bar shows on the hovered row. When the mouse isn't over the list, the hover bar shows on the cursor row only after the cursor has been still for 400ms, and hides on `j`/`k`. That's how keyboard users find the actions.

### 5.4 Hover action bar

- One shared `NSView`, a sibling above the table's clip view (not inside the row), repositioned on hover change.
  It sits at the top right of the hovered row: right edge at 20 from the pane edge, its vertical center on the row's top edge + 4, clamped so it never goes above the visible top (then it sits 4 inside the row).
- 34 high, radius 8, `bgRaised` fill, 1pt `borderStrong` @ 60% border, the floating shadow (§1.3).
- Buttons are 30×30 (inset 2), radius 6, with a 14pt symbol in `textMuted`. On hover: `bgHover` fill and `textStrong` symbol, plus a tooltip after 500ms in the form "Reply in thread  r".
  Order, left to right:

| symbol | action | key |
| --- | --- | --- |
| `face.smiling` + small `plus` | add reaction (opens the emoji picker) | `+` |
| quick reactions: the 3 most used emoji, as 16pt glyphs (local stats) | toggle that reaction | `1` `2` `3` |
| `bubble.left` | reply in thread | `r` |
| `arrowshape.turn.up.right` | share / copy message link | `c` |
| `bookmark` | save for later (local) | `s` |
| `pencil` | edit, own messages only | `e` |
| `trash` | delete, own messages only, tinted `unreadRed` on hover | `⌫` / `d` |
| `ellipsis` (vertical) | menu: Copy text, Copy link, Mark unread from here, Open in Slack, Remind me… | `.` |

- A 1pt `border` divider (16 high) separates the quick reactions from the rest.
- Delete asks inline: the bar becomes "Delete message?" in 12 `text` + [Cancel] [Delete] (Delete is `unreadRed` fill, white). ↩ confirms, esc cancels. Then it goes through the Outbox with the `z` undo toast.

### 5.5 Body formatting (mrkdwn → attributes)

Extend `Mrkdwn.runs` to a block model: `paragraph`, `quote`, `code(String)`, `list(ordered: Bool, items)`, with inline runs `bold`, `italic`, `strike`, `code`, `mention`, `channel`, `link`, `emoji`.

- `*bold*` → `body` semibold, `textStrong`. `_italic_` → italic trait (via `NSFontDescriptor.withSymbolicTraits(.italic)`, cached). `~strike~` → `.strikethroughStyle` single and `textMuted`.
- Inline `` `code` ``: `mono` at 12.5, `codeInline` fg. The background is a rounded rect, radius 3, 1pt `codeBorder`, padding 2 horizontally. Draw it with a custom `NSLayoutManager.fillBackgroundRectArray` override (or a `.backgroundColor` attribute when the radius isn't needed at first). Don't use separate views.
- Code block (```` ``` ````): its own paragraph, `mono` `text`, fill `codeBg`, 1pt `codeBorder`, radius 4, padding 8 on every side, full content width, 4 above and below.
  Draw it as a `NSTextBlock` (`NSTextTableBlock` with one cell) with background color, border width 1 and padding 8. It lays out in the same text pass, so there's no extra view. Lines don't wrap (long lines clip at the block edge). A horizontal scroll is out of scope; a hover "Copy" button (`doc.on.doc` 12pt) at the block's top right is in scope.
- Blockquote (`>` lines): a paragraph with headIndent and firstLineHeadIndent 12. A 4pt bar, radius 2, `quoteBar`, spans the quote's height at x 0 of the content column. Draw it from the same `NSTextBlock` with a left border only: `setWidth(4, type: .absoluteValueType, for: .border, edge: .minX)`, with the border color `quoteBar`.
- Lists: `•` / `1.` markers, headIndent 18, a tab stop at 18, 2 paragraph spacing.
- Links: `link` color, no underline; underline only on hover (track it with `NSTextView`'s `.cursorRect` handling, which is free).
  Bare URLs that Slack sends as `<url>` without a label are shown the way the screenshot does: `link` icon (`link` 11pt) + the host/path, shortened to 48 chars with a middle "…", on a `linkChipBg` radius 4 background.
  ⌘-click opens in the background; a click opens in the default browser. Every URL in the visible message also goes into ⌘K's "Links" section.
- Mentions: `@Name` / `#channel` as 14 medium on the `mention` bg, radius 3, padding 1/2 (done the same way as inline code). Me, `@here`, `@channel`: `mentionMe`. A row that mentions me gets the `mentionMeRow` fill, plus a 2pt `#ECB22E` left bar when it isn't under the cursor.
- Emoji `:name:` → the glyph (the current `Emoji.replace`). A message made only of 1 to 3 emoji renders them at 28pt ("jumbomoji").
- `(edited)`: 11.5 `textMuted`, after a space, inline at the end of the last paragraph.
- Link unfurls (attachments with title/text): a card under the body, 8 above. 1pt `border`, radius 8, padding 12/14, max width 520. A 4pt left bar in the attachment `color` or `border`. Title 14 semibold `textStrong`, text 13 `text` with 3 lines max, footer 12 `textMuted` with a 16pt favicon. The thumbnail on the right is 80×80 radius 6 (lazy, cached like avatars). Milestone 3; the layout slot is reserved now.

Attributed strings are built once per message per appearance in `show()` and cached by `(ts, edited)`. They are not rebuilt on hover or on cursor moves.

### 5.6 Reactions

- A row under the body, 6 above, with wrapping. Pills are 24 high, radius 12, padding 0/8, spacing 4 horizontal and 4 vertical.
- Content: emoji 15pt + 4 + count in `small` semibold, monospacedDigit.
  - not mine: `reactBg` fill, `reactBorder` 1pt, count `text`.
  - mine: `reactMineBg` fill, `reactMineBorder` 1pt, count `#1D9BD1` (dark) / `#1264A3` (light).
  - hover: border `textMuted`. A tooltip lists who reacted ("Mira and Tomas reacted with :eyes:").
- The trailing "add" pill is 24×32, `reactBg`, with `face.smiling` 14pt `textMuted` and a 9pt `plus` badge (the screenshot shows it). It only shows while the row is hovered or under the cursor. Its slot is always reserved, so the row height doesn't jump.
- Clicking a pill toggles my reaction optimistically: the store updates first, then the outbox sends. On failure, it reverts and an error toast appears.
- Drawing: each reaction row is one `ReactionStrip` view (in the recycled cell) that draws its pills in `draw(_:)` from a precomputed `[PillLayout]`. Hit testing works from the same array. No `NSButton` per pill.

### 5.7 Thread summary (in the channel only)

- 4 above. 24 high, a hover target that spans the content width, radius 6, with a `bgRaised` fill + 1pt `border` on hover only.
- Up to 3 replier avatars 20×20 radius 4, spacing 4. Then 8, "3 replies" in `small` semibold `link`, then 8, "Last reply 2 hours ago" in `small` `textMuted`. On hover that becomes "View thread" + `chevron.right` 10pt at the right.
- If the thread has a draft: `pencil` 11pt `textMuted` + "Draft" before the reply count.
- If the thread has unread replies (local `thread_last_read`): the count is semibold with a 6pt `unreadRed` dot before it.

### 5.8 "New messages" divider

- A separate row kind (its own identifier), 24 high, inserted after the message whose ts == `lastRead` at the moment the channel opened. It stays until the channel is closed, even after `mark`, as Slack does.
- 1pt `unreadRed` line from x 20 to the right edge - 20, at the vertical center. At the right end there's a label, "New", 11 bold `unreadRed`, with `bg` padding 0/6 so it cuts the line.
- It's not focusable: `j`/`k` skip it.

### 5.9 Date separators

- A row kind, 40 high, inserted whenever the day changes between consecutive messages (and before the first loaded message).
- A 1pt `border` line full width at the center. A centered pill: 26 high, radius 13, `bg` fill, 1pt `border`, padding 0/14, text 12 semibold `textStrong`: "Today", "Yesterday", "Wednesday, October 7th" (this year), "October 7th, 2025".
- **Sticky**: the current day's pill floats at the top of the visible area, 8 below the header (the screenshot's "Today ⌄" is that floating pill over the text). It's a single overlay view, updated in `scrolled()` from a precomputed `[dayStartRow]` with a binary search. It gets the floating shadow when it isn't over its own separator. Clicking it opens a menu: Today, Yesterday, Last week, Jump to date… (scrolls to the first cached message of that day, and fetches if needed).

### 5.10 Floating jump pills

All of them are overlay views above the clip view. They fade over 0.15s via `animator().alphaValue`, never re-layout.

- **Jump to unread**: at the top center, 12 below the header (or below the sticky date). It shows when the "New messages" divider is above the visible area. 28 high, radius 14, `unreadRed` fill, white 12 semibold:
  "↑ 12 new messages" + a 1pt white @ 40% separator + "Mark as read" (`checkmark` 10pt). Click: scroll the divider to 1/3 from the top. Esc while it's visible: mark as read. Key: `g u` (existing).
- **Unread mentions**: the same style but `accentPill`, "↑ 2 mentions" when an unseen mention row is above. It replaces "Jump to unread" when both apply. `g m` jumps to the next one.
- **Jump to bottom**: at the bottom right, 16 from the right and 12 above the composer. A 32×32 circle with `bgRaised` fill, 1pt `border`, shadow, and `arrow.down` 13pt semibold `text`. It shows when the view is more than 1.5 screens from the bottom. When new messages arrive while scrolled up, it grows into a pill reading "↓ 3 new" in `link` color. Key: `G` (existing) or ⌘↓.

### 5.11 Scroll behavior

- Opening a channel with unreads: put the divider at 1/3 from the top (not the bottom), and put the cursor on the first unread.
  Opening a channel with no unreads: stick to the bottom.
- When at the bottom (within 4pt), new messages keep it pinned. Otherwise the content doesn't move: anchor on the first visible ts (the existing `visibleTop`).
- Prepend on load-older keeps the same anchor with no visible jump (adjust `bounds.origin.y` by the inserted height in one transaction).
- Mark as read when the bottom is visible and the window is key, debounced by 1.5s. Marking never happens in headless runs without a script `key`.
- Scroll position per conversation (anchor ts + offset) is saved in the store's kv table, so switching back restores it exactly.

## 6. Thread pane

- Header 49 high, like the channel header: "Thread" in `title`, and after it "#engineering" in 13 `textMuted` (clickable, which jumps there). Close `xmark` 14pt at the right, 28×28 hover square. Key: esc.
- Body: the same `MessageList` class (`inThread = true`).
  - The parent message is shown in full (avatar and name always).
  - Under it: a 16-high row with "3 replies" in 12 `textMuted` + a 1pt `border` line filling the rest, at x 20 to x right - 20.
  - The replies, with the same grouping rules.
- The thread's own composer is at the bottom (§7), placeholder "Reply…". Below it, a 20-high checkbox row: "Also send to #engineering" in 12 `textMuted` (`reply_broadcast`).
- Thread "New" divider from the local thread read state.
- Focus: Tab / ⌘→ moves the keyboard focus into the thread, and ⌘← / esc moves it back. The unfocused pane's cursor dims (existing `focused`).
- Note from the current build: pressing `r` on a message with no replies shows only that message in the pane, which is correct. It still needs the composer, which turns it into "Start a thread".

## 7. Composer

- At the bottom of the message pane and the thread pane. Margins: 20 left/right, 20 bottom (Slack: 20), 0 top. The list gets a 12pt bottom content inset, so the last message clears the box.
- Box: radius 8, 1pt `border` (idle) / `borderStrong` (focused), fill `bgHover` (dark) / `bg` (light).
- Text: an `NSTextView` in an `NSScrollView`, `body` font, text inset 12/10. It grows from one line (min box height 42 without the toolbar) to 50% of the pane height, then scrolls.
  The placeholder is drawn in `textMuted`: "Message #engineering", "Message Mira", "Reply…".
- Toolbar (inside the box, under the text, 36 high, padding 0/6): 28×28 buttons, 15pt `textMuted`, radius 6 hover `bgHover`:
  `plus` (attach, milestone 3), a 1pt divider, `bold` `italic` `strikethrough` `chevron.left.forwardslash.chevron.right` (code) `list.bullet` (these wrap the selection in `*` `_` `~` `` ` ``, as ⌘B ⌘I ⌘⇧X ⌘⇧C do), a 1pt divider, `face.smiling`, `at`.
  On the right: the send button, 28×28 radius 6 with `paperplane.fill` 14pt. It's `success` fill with white when there's text, and `textFaint` with no fill when empty.
  The toolbar shows only while the composer is focused or holds text. Otherwise the box is a single 42-high line. That's the keyboard-first default, and it reclaims space.
- Formatting while typing: syntax runs (`*x*`, `` `x` ``, ```` ``` ````) get their formatted look live, with the markers shown in `textFaint`. One `NSTextStorage` delegate pass over the edited paragraph only.
- Keys: ↩ sends, ⇧↩ inserts a newline, ↑ in an empty composer edits my last message, esc blurs (back to the list cursor), ⌘Z undoes typing, `z` (from the list) undoes a send.
- Typing indicator: 18 high under the box, 11.5 `textMuted`, "Mira is typing…" (Socket Mode, milestone 3). The slot is reserved, so nothing jumps.
- **Drafts**: the text and selection are saved per `(conversation, threadTS?)` in a store `drafts` table, debounced by 400ms and on every conversation switch. They're restored on open. The sidebar pencil and the thread summary "Draft" read from it. Sending deletes the draft row in the same transaction as the outbox insert.
- When writes are off for the workspace (`writes:false`), the box shows a 1-line note instead of the toolbar: `lock` 11pt + "Read-only workspace" in 12 `textMuted`, and ↩ shows an error toast. It never sends silently.

### 7.1 @ autocomplete

- Triggered by `@` at a word start; `#` opens the same popup for channels and `:` (2+ chars) for emoji.
- A popup anchored above the caret line: its left edge on the `@`, bottom 6 above the box top. Width 320, at most 8 rows, rows 32 high. `bgRaised`, radius 8, 1pt `border`, shadow.
- Row: 20×20 avatar radius 4 at x 10, 8, display name 13 semibold `textStrong`, 6, real name/handle 12 `textMuted`. At the right, a tag for bots ("APP", as in §5.1) or for groups ("@here — notify everyone online"). The presence dot is drawn on the avatar.
- The highlighted row has a `cursorTint` fill + a 2pt `cursor` left bar (the same language as the list cursor).
- Ranking: people and bots who are members of this conversation first, then recent DM partners, then everyone. Prefix match on display name, real name, then handle. `@here`, `@channel` and `@everyone` come last unless typed.
- ↑/↓ or ⌃n/⌃p move, ↩ or Tab inserts, esc closes. It inserts a token that is displayed as `@Mira` with `mention` styling, is atomic (deleted as one character), and is sent as `<@U123>`.
- The member list comes from the cache (`users` + `conversation_members`). Nothing hits the network per keystroke.

## 8. Edit in place

- `e` on my message (or `pencil` in the hover bar, or ↑ in an empty composer) swaps the row's body for an inline composer. It's the same component as §7, with the text being the message's mrkdwn source.
  The row keeps its avatar/name. The editor box has radius 8, 1pt `borderStrong`, fill `bg`, and is inset to the content column.
- Under the box, in 12 `textMuted`: "escape to cancel • enter to save". [Cancel] (plain) and [Save] (`success` fill, white, radius 6, 24 high) are right aligned.
- While editing, the row is `mentionMeRow`-free and drawn with a `#ECB22E` @ 8% fill (Slack's yellow editing tint).
- Saving updates the store optimistically, the row shows "(edited)" immediately, and the outbox does the work with `z` undo. On failure, it reverts and an error toast appears.
- Only one editor exists at a time. It's a single reusable view that is placed over the cell (not inside it), with the row height overridden while editing.

## 9. Toasts

- At the bottom center of the message pane, 16 above the composer. 32 high, radius 8, padding 0/14, the floating shadow.
- Info: `textStrong` @ 92% inverted (the current `labelColor` approach is fine), 12.5 medium.
  Success: a leading `checkmark.circle.fill` 13pt `success`. Error: `unreadRed` fill, white text, `exclamationmark.triangle.fill`, a 6s duration, and the text is also written to the log (existing).
- Undo toast: "Message sent · Undo (z)", with "Undo" as a `link`-colored button. It counts down: a 2pt `link` progress line along the bottom edge, animated with a `CABasicAnimation` on `strokeEnd` (no timers that re-layout).
- They stack upward with 6 spacing, 3 at most.

## 10. ⌘K palette

- An overlay inside the window (the current `Overlay`), 640 wide, top at 72. Scrim black @ 35% (dark) / 20% (light). Card `bgRaised`, radius 12, 1pt `border`, shadow radius 24 / opacity 0.35.
- Field: 52 high, `magnifyingglass` 16pt `textMuted` at x 18, text 17 regular at x 44, placeholder "Search conversations, people, commands, links…". A 1pt `border` line under it.
- Results: max height 420, then the list scrolls. Rows are 36 high (not 40 with two lines). Section headers are 26 high: 11 semibold `textMuted` with 0.5 letter spacing at x 18. Their reuse ids differ, so rows recycle.
- Row: icon box 20×20 at x 14 (a channel glyph, a 20pt avatar radius 4, an SF Symbol for commands, `link` for links, `text.bubble` for messages). Title at x 44 in 13.5 regular `textStrong`, with the matched characters semibold. Detail after 8, in 12 `textMuted`, truncating first. At the right, the shortcut keycap(s): 11 medium `textMuted` on `codeBg`, radius 4, padding 1/5, 2 apart (e.g. `g` `u`, `⌘R`).
- Highlighted row: `cursorTint` fill, radius 6, inset 6, + a 2pt `cursor` left bar.
- Sections, in this order, each capped at 5 while a query is typed (all with an empty query, scrolling), and dropped when empty:
  1. **Conversations**: channels and DMs. Empty query: recent conversations by last opened (local), unread ones marked bold with the badge.
  2. **People**: users and bots. ↩ opens their DM. ⌘↩ inserts `@name` into the composer.
  3. **Commands**: everything the app can do, generated from one `Command` table that both the router and the palette read, so nothing is ever missing from ⌘K:
     Jump to unreads, Next/previous unread channel (⌥↓/⌥↑), Mark channel read, Mark all read, Search messages, Find in channel, Open thread, Close thread, Edit last message, React…, Star/unstar channel, Move channel to section…, New section…, Collapse all sections, Toggle sidebar (⌘⇧D), Toggle dark/light, Copy channel link, Open channel in Slack, Refresh (⌘R), Switch workspace: <name>, Open log, Open config, Quit.
  4. **Links**: the URLs from the current conversation (newest first), then all cached messages through fts. ↩ opens, ⌘↩ copies. The detail is "#channel · author · time".
  5. **Messages**: fts5 hits from the cache, the same as `/`. ↩ jumps to the message in context (opens the conversation and puts the cursor on it). The detail is "#channel · author · time". It comes last and is filled 120ms after the other sections, so typing never waits on fts.
  - Typing a URL (`http…` or a domain) puts an "Open <url>" row first.
  - Prefixes scope the palette: `#` channels, `@` people, `>` commands, `/` messages.
- Footer: 30 high, a 1pt `border` top, 11 `textMuted` keycaps: "↑↓ navigate  ↩ open  ⌘↩ alt action  esc close".
- Matching is a single in-memory fuzzy scorer over a list prebuilt when the palette opens: under 2ms for 5k items, on the main thread. Only fts runs off main.

## 11. Search overlay (/)

The same card as ⌘K. Rows are 52 high: line 1 is "#channel · author · time" in 12 `textMuted`, line 2 is the snippet in 13.5 `text`, with the matched terms on the `mentionMe` bg. A "From Slack" section header separates remote hits. The note line becomes the footer.

## 12. Keyboard cursor summary

| place | cursor look |
| --- | --- |
| message list (focused) | 3pt `cursor` left bar + `cursorTint` |
| message list (unfocused) | 3pt `textFaint` bar + 4% tint |
| sidebar | the `sbSelectedBg` fill; + a 2pt `cursor` inner ring when the sidebar has focus |
| palette, autocomplete, menus | `cursorTint` + 2pt `cursor` left bar, radius 6 |
| hover (anywhere) | a fill only (`bgHover` / `sbHover`), never a bar |

The bar always means the keyboard and a plain fill always means the mouse, so the two never look alike.

## 13. Motion

- 0.12–0.18s ease-out for fades and chevrons. No animated layout of table rows except collapsing a section (`removeRows(at:withAnimation: .effectFade)`, nothing else).
- Under `NSWorkspace.accessibilityDisplayShouldReduceMotion` every duration is 0.

## 14. Performance budget for this spec

- `relayctl bench 8` must not regress. Avatars, unfurl thumbnails and emoji are never on the first-frame path: the first frame draws initials placeholders from sqlite data only.
- Per visible row, at most: 1 row view, 1 cell, 1 text view, 1 avatar layer, 1 reaction strip, 1 thread-summary view. All recycled.
- Height cache by `(ts, editedTS, reactionsHash, width)`. Hover, cursor and the hover bar never invalidate heights.
- The hover bar, sticky date, jump pills, toast and editor are single instances that move. They are not created per row.

## 15. Current build vs this spec (snapped on the emulator, :4033)

- The sidebar header says "2027dev (emulated)" in 15 bold with an UNREAD section first: replace it with §3. Unread becomes weight + badge.
- Messages have no avatars or grouping, so 60 "mira / tomas" lines repeat names: §5.1–5.2.
- Mentions are orange text: switch them to the §1.1 mention pills.
- Reactions are plain text (`👍 1   👀 2`): §5.6.
- "3 replies ↩" is gray text: §5.7.
- There is no composer, divider, date separator or jump pill yet.
- ⌘K rows are 2-line, 40 high, with no sections or icons: §10.
- The cursor (left bar + tint) is already the right idea. Keep it and recolor it.
- Both `MessageList.rowViewForRow` and `Sidebar.viewFor` allocate views per row: recycle them (see the rendering rules at the top).
