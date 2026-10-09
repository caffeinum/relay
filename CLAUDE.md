# relay

A native macOS Slack client. SwiftPM, built with the command line tools only.
The approved plan is in README.md.

- The sibling app is ~/Github/caffeinum/mail (Reply). Reuse its patterns: Store (sqlite WAL + fts5), Outbox with undo, the keychain via /usr/bin/security, POST_SCRIPT-style UI scripting, and build.sh / test.sh.
- The workspace is 2027dev.slack.com, through one internal Slack app with user-token scopes and Socket Mode. Do not use the browser session token (xoxc). The operator ruled it out.
- Writes against 2027dev are approved (operator, 2026-10-08 20:31 PDT: "implement write version from the start"). The starter config has writes:true for it. When testing writes on the real workspace, use your own DM (self-DM) or a throwaway message you delete right after; never post into others' channels or DMs as a test. Develop against caffeinum/emulate's Slack emulator. Ask @emulate for missing methods (search.messages, users.conversations and unread counts landed in 46b9fd2; Socket Mode is pending, beads-jgdc).
- Never print tokens.

## Layout
- The name lives in one constant, `Sources/RelayCore/Brand.swift` (`Brand.name`). Bundle id `com.caffeinum.relay`, keychain service `relay` (accounts `<workspace>.user`, `<workspace>.app`), config `~/.config/relay/config.json`, cache `~/Library/Application Support/com.caffeinum.relay/<workspace>.sqlite`, env prefix `RELAY_` (HOME, CONFIG, BENCH, SCRIPT, OFFLINE). build.sh reads the name from Brand.swift.
- `./build.sh` → build/Relay.app + build/relayctl. `./test.sh` runs swift-testing.
- `dev/emulator.sh` starts the slack emulator on :4003 (tmux `relay-emulator`) and seeds it; the starter config (`relayctl init`) points the `emulator` workspace at it with token `xoxp-emu-aleks`. Real workspaces never take an inline token.
- Writes are refused in `Slack.call` unless the workspace has `"writes": true`.
- `relayctl bench N` measures cold start: app-reported first frame and window-on-screen from outside.
- `RELAY_HEADLESS=1` runs with no Dock tile and the window off screen; `RELAY_SCRIPT` snaps still render. Use it for every visual check while the operator is at the machine, never pop the window in front of them.
- `PORT=4013 dev/emulator.sh` runs a second emulator (tmux `relay-emulator-<port>`) so parallel work doesn't share state.
- `dev/slack-manifest.json` is the internal app's manifest; `dev/store-token.sh <ws>.user|<ws>.app` moves a token from the clipboard to the keychain.
- Message list (RENDER): bodies are drawn by `BodyView` straight from a TextKit 1 stack (no NSTextView: its first init costs ~25 ms), and SF Symbols stay off the first-frame path (catalog load ~100 ms; `Symbols.warm()` runs after the first show). Click targets use `.relayLink`, not `.link`, so TextKit doesn't underline them. Heights: single-line bodies take a CoreText fast path, the rest are measured in parallel; building attributed strings stays serial (it contends across threads).
- Script verbs for headless checks: `hover <i>`, `edit <i>`, `confirm <i>`, `unread [ts]`, `load <n>`, `scroll <dy>`, `me`, `appearance light|dark`, `timing` (negative i counts from the end). `PORT=4023 SEED_RICH=1 dev/emulator.sh` adds #design/#firehose rich content.
