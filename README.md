# Relay

A native macOS Slack client that opens instantly and runs from the keyboard.
The Slack web app is slow, and even editing a message takes Up + E.

Not to be confused with team2027/chatbot, an unrelated project.

## Plan

**How it works.** A native macOS app built the same way as
[Reply](https://github.com/caffeinum/reply): AppKit, and a local sqlite + fts5
cache that draws the first frame from disk in under 150 ms. It syncs when you
open it, with no background process. It talks to Slack through an *internal*
Slack app installed in the workspace, using user-token scopes so it acts as
you: `conversations.list/history/replies/mark`, `users.*`,
`chat.postMessage/update/delete`, `reactions.*`, `files.*`, `search.messages`.
Live updates arrive over Socket Mode, a websocket that needs no public server.
Tokens live in the keychain.

The app is internal on purpose. Since May 2025, apps distributed outside
Slack's marketplace get one `conversations.history` call per minute, 15
messages each. Internal customer-built apps keep Tier 3, about 50 calls a
minute. Development and tests run against the Slack emulator in
[caffeinum/emulate](https://github.com/caffeinum/emulate), so no real
workspace is touched until the owner says go.

**UI and keys.** One workspace, one chat. Workspaces live in config, and
switching is a single ⌘K command, so the UI never shows a workspace list. The
sidebar shows channels and DMs, unread first. Sections such as Starred or
Customers are local config, because Slack's public API doesn't expose sidebar
sections. The message list sits in the middle and the thread pane on the
right.

| keys | action |
| --- | --- |
| `j` / `k` | move by message |
| `e` | edit your own message |
| `r` | reply in thread |
| `+` | react |
| `/` | search: local and instant, then Slack's search for older messages |
| `g u` | jump to unreads |
| `⌘K` | jump to a channel, or run any command |
| `z` | undo a send or edit for a few seconds |

Shared with Reply: one keymap file in `~/.config`, the cache / outbox /
keychain pattern, and a local CLI (`relayctl`) that gives agents raw access to
the same objects.

## Milestones

1. Read-only. Channels, DMs, threads, unreads and search, against the emulator
   and the real workspace, with cold start measured honestly.
2. Writes: send, edit, react, mark read, with an undo window.
3. Files, mentions, huddle links, notifications.
