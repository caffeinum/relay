#!/bin/bash
# Adds rich messages to a running emulator (see emulator.sh, or SEED_RICH=1
# there): #design gets bold/italic/strike, inline code, code blocks, quotes,
# lists, mentions of people/here/groups, links, emoji, reactions from several
# people and a long thread; #firehose gets 2000 messages for scroll and
# show() timing. Text goes in already escaped, as Slack stores it.
#   PORT=4023 dev/seed-render.sh
set -euo pipefail
PORT="${PORT:-4003}"
URL="http://localhost:$PORT"

api() { # token method key=value...
  local tok="$1" m="$2"; shift 2
  local args=(); for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  curl -sf -X POST "$URL/api/$m" -H "Authorization: Bearer xoxp-emu-$tok" ${args[@]+"${args[@]}"}
}
field() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1"; }
uid() { api "$1" auth.test | field "['user_id']"; }
create() { api aleks conversations.create name="$1" | field "['channel']['id']"; }

ALEKS=$(uid aleks); MIRA=$(uid mira); TOMAS=$(uid tomas)
DES=$(create design); FIRE=$(create firehose)
for who in mira tomas; do for c in $DES $FIRE; do api $who conversations.join channel=$c >/dev/null; done; done
GEN=$(api aleks conversations.list types=public_channel limit=200 | python3 -c "import sys,json;print([c['id'] for c in json.load(sys.stdin)['channels'] if c['name']=='general'][0])")

post() { api "$1" chat.postMessage channel="$2" text="$3" | field "['ts']"; }
react() { api "$1" reactions.add channel="$2" timestamp="$3" name="$4" >/dev/null; }

post mira $DES "morning! the *new list* is _almost_ there, ~old renderer~ is gone" >/dev/null
post mira $DES "two things left: \`heightOfRow\` caching and the hover bar" >/dev/null
T1=$(post tomas $DES "here's the parser entry point:
\`\`\`
public static func parse(_ s: String) -> [Block] {
    let u = Array(s.unicodeScalars)
    var out: [Block] = []   // paragraphs, quotes, code, lists
    return out
}
\`\`\`
it's one pass, no regex")
react mira $DES "$T1" eyes; react aleks $DES "$T1" eyes; react aleks $DES "$T1" white_check_mark
post aleks $DES "&gt; it's one pass, no regex
&gt; *linear* in the input
nice. what about \`snake_case_names\` and 2*3*4?" >/dev/null
post mira $DES "plan for today:
• cache heights by (ts, edited, width)
• recycle row views
• draw reaction pills without buttons" >/dev/null
post mira $DES "1. parse
2. layout
3. draw" >/dev/null
T2=$(post tomas $DES "<@$ALEKS> can you review <https://github.com/team2027/evals/pull/1156>? also see <https://docs.revyl.com/infrastructure|the infra doc>")
react mira $DES "$T2" +1; react tomas $DES "$T2" +1; react aleks $DES "$T2" rocket
post mira $DES "<!here> deploy at 5 :rocket: ping <@$TOMAS> if it breaks" >/dev/null
post tomas $DES ":tada::tada::tada:" >/dev/null
T3=$(post aleks $DES "shipping the render branch tonight, thread for notes :thread:")
for i in $(seq 1 12); do
  who=$([ $((i % 3)) = 0 ] && echo aleks || ([ $((i % 3)) = 1 ] && echo mira || echo tomas))
  api $who chat.postMessage channel=$DES thread_ts=$T3 text="note $i: $([ $((i % 4)) = 0 ] && echo '`ok` with *bold*' || echo 'looks fine')" >/dev/null
done
react tomas $DES "$T3" heart; react mira $DES "$T3" heart; react mira $DES "$T3" fire
post mira $DES "a &amp; b &lt;tag&gt; stays literal, and :not_an_emoji: stays too" >/dev/null
post aleks $DES "let me fix that" >/dev/null
api aleks chat.update channel=$DES ts="$(post aleks $DES "typo hree")" text="typo here" >/dev/null

for i in $(seq 1 2000); do
  who=$([ $((i % 3)) = 0 ] && echo mira || echo tomas)
  case $((i % 5)) in
    0) t="row $i: *bold* and \`code\` with a longer line that should wrap at narrow widths so heights differ between rows";;
    1) t="row $i";;
    2) t="row $i: <https://example.com/$i|link $i> :+1:";;
    3) t="row $i:
&gt; quoted";;
    *) t="row $i: _it_";;
  esac
  api $who chat.postMessage channel=$FIRE text="$t" >/dev/null &
  [ $((i % 20)) = 0 ] && wait
done
wait
echo "rich seed on $URL: #design ($DES), #firehose ($FIRE)"
