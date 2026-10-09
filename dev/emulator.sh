#!/bin/bash
# Starts caffeinum/emulate's Slack emulator on :4003 in a detached tmux
# session and fills it with channels, a DM, threads and enough history to
# scroll. Re-running restarts it from the seed (the emulator is in-memory).
#   EMULATE_DIR   checkout of caffeinum/emulate (default ~/.paw/repos/vercel-labs/emulate)
set -euo pipefail
cd "$(dirname "$0")"
EMULATE_DIR="${EMULATE_DIR:-$HOME/.paw/repos/vercel-labs/emulate}"
PORT="${PORT:-4003}"
URL="http://localhost:$PORT"
tmux kill-session -t relay-emulator-$PORT 2>/dev/null || true
tmux new-session -d -s relay-emulator-$PORT "node '$EMULATE_DIR/packages/emulate/dist/index.js' start --service slack --port $PORT --seed '$PWD/emulate.yaml' 2>&1 | tee /tmp/relay-emulator-$PORT.log"
for _ in $(seq 50); do curl -sf -o /dev/null -X POST "$URL/api/auth.test" -H "Authorization: Bearer xoxp-emu-aleks" && break; sleep 0.2; done

api() { # token method key=value...
  local tok="$1" m="$2"; shift 2
  local args=(); for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  curl -sf -X POST "$URL/api/$m" -H "Authorization: Bearer xoxp-emu-$tok" ${args[@]+"${args[@]}"}
}
chan() { api aleks conversations.list types=public_channel limit=200 | python3 -c "import sys,json;print([c['id'] for c in json.load(sys.stdin)['channels'] if c['name']=='$1'][0])"; }
ts() { python3 -c "import sys,json;print(json.load(sys.stdin)['ts'])"; }

GEN=$(chan general); ENG=$(chan engineering); CUS=$(chan customers); RND=$(chan random)
for who in mira tomas; do for c in $GEN $ENG $CUS $RND; do api $who conversations.join channel=$c >/dev/null; done; done
for c in $GEN $ENG $CUS $RND; do api aleks conversations.join channel=$c >/dev/null; done

api mira chat.postMessage channel=$GEN text="morning all, standup moved to 10:30" >/dev/null
api tomas chat.postMessage channel=$GEN text="ok :+1:" >/dev/null
for i in $(seq 1 60); do api $([ $((i % 2)) = 0 ] && echo mira || echo tomas) chat.postMessage channel=$ENG text="build #$i: $([ $((i % 7)) = 0 ] && echo 'flaky test in sync' || echo 'green')" >/dev/null; done
T=$(api mira chat.postMessage channel=$ENG text="the cold start regressed to 400ms, anyone looked at why?" | ts)
api tomas chat.postMessage channel=$ENG thread_ts=$T text="fts5 rebuild on open, i think" >/dev/null
api aleks chat.postMessage channel=$ENG thread_ts=$T text="yes, moving it after the first frame" >/dev/null
api mira chat.postMessage channel=$ENG thread_ts=$T text="nice, ship it" >/dev/null
api aleks chat.postMessage channel=$CUS text="acme renewal call is thursday" >/dev/null
api mira chat.postMessage channel=$CUS text="I'll prep the usage numbers for <@$(api aleks auth.test | python3 -c 'import sys,json;print(json.load(sys.stdin)["user_id"])')>" >/dev/null
api tomas chat.postMessage channel=$RND text="anyone want coffee? see <https://example.com/menu|the menu>" >/dev/null
MIRA=$(api mira auth.test | python3 -c 'import sys,json;print(json.load(sys.stdin)["user_id"])')
DM=$(api aleks conversations.open users=$MIRA | python3 -c 'import sys,json;print(json.load(sys.stdin)["channel"]["id"])')
api mira chat.postMessage channel=$DM text="hey, got a minute for the deck?" >/dev/null
api aleks chat.postMessage channel=$DM text="sure, after lunch" >/dev/null
api mira chat.postMessage channel=$DM text="thanks! sending the draft now" >/dev/null
echo "slack emulator on $URL (tmux: relay-emulator-$PORT), seeded"
if [ -n "${SEED_RICH:-}" ]; then PORT=$PORT ./seed-render.sh; fi
