# chat

A native macOS Slack client. SwiftPM, built with the command line tools only.
The approved plan is in README.md.

- The sibling app is ~/Github/caffeinum/mail (Reply). Reuse its patterns: Store (sqlite WAL + fts5), Outbox with undo, the keychain via /usr/bin/security, POST_SCRIPT-style UI scripting, and build.sh / test.sh.
- The workspace is 2027dev.slack.com, through one internal Slack app with user-token scopes and Socket Mode. Do not use the browser session token (xoxc). The operator ruled it out.
- Stay read-only against the real workspace until the operator says yes. Develop against caffeinum/emulate's Slack emulator. Ask @emulate for missing methods (Socket Mode and search.messages are not there yet).
- Never print tokens.
