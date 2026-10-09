#!/bin/bash
# Moves a token from the clipboard into the keychain without it touching
# argv, a file or the terminal, then clears the clipboard.
#   dev/store-token.sh 2027dev.user    (expects xoxp-…)
#   dev/store-token.sh 2027dev.app     (expects xapp-…)
set -euo pipefail
ACCOUNT="$1"
SERVICE=$(sed -n 's/.*static let name = "\(.*\)".*/\1/p' "$(dirname "$0")/../Sources/RelayCore/Brand.swift" | tr '[:upper:]' '[:lower:]')
TOKEN=$(pbpaste | tr -d '[:space:]')
case "$ACCOUNT:$TOKEN" in
  *.user:xoxp-*|*.app:xapp-*) ;;
  *) echo "clipboard doesn't hold the right kind of token for $ACCOUNT (want xoxp- for .user, xapp- for .app)" >&2; exit 1 ;;
esac
printf 'add-generic-password -U -A -s %s -a %s -l "%s slack token" -w %s\n' "$SERVICE" "$ACCOUNT" "$SERVICE" "$TOKEN" | security -i >/dev/null
printf '' | pbcopy
security find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null && echo "stored $SERVICE/$ACCOUNT (${#TOKEN} chars)"
