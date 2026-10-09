# relay

A native macOS Slack client. SwiftPM, built with the command line tools only.
The approved plan is in README.md.

- The sibling app is ~/Github/caffeinum/mail (Reply). Reuse its patterns: Store (sqlite WAL + fts5), Outbox with undo, the keychain via /usr/bin/security, POST_SCRIPT-style UI scripting, and build.sh / test.sh.
- The workspace is 2027dev.slack.com, through one internal Slack app with user-token scopes and Socket Mode. Do not use the browser session token (xoxc). The operator ruled it out.
- Stay read-only against the real workspace until the operator says yes. Develop against caffeinum/emulate's Slack emulator. Ask @emulate for missing methods (search.messages, users.conversations and unread counts landed in 46b9fd2; Socket Mode is pending, beads-jgdc).
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
