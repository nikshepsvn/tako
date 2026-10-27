#!/bin/bash
# End-to-end test of Tako Link: two hidden Debug instances on this Mac (A "Alex" and B "Blake",
# each with its own HT_HOME and browser port) turn Link on, find each other over Bonjour, pair
# (both confirm the code with `ht link confirm`), and their Sumis (fake Claude CLIs driving the
# real `ht mcp` and its peer tool) exchange a chat, an ask and an approved answer. Prints one
# PASS/FAIL line per check; exits non-zero if any failed.
#
#   scripts/link-smoke.sh               build if sources changed, then run
#   LINK_BUILD=0 scripts/link-smoke.sh  skip the build
#
# Optional: macOS may ask once whether the Debug app may find devices on the local network
# (Bonjour), and the firewall whether it may accept incoming connections; allow both.
#
# Safety: `ht` is pointed at each instance's HT_HOME (a surrounding Tako's session variables are
# dropped); only processes carrying this run's marker are signalled; the installed app, ~/.tako
# and ~/.hyperterm are never touched. Both data folders are removed at the end.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/DerivedData/Build/Products/Debug/Tako.app"
EXE="$APP/Contents/MacOS/Tako"
HT="$APP/Contents/Resources/bin/ht"
HOME_A="${TAKO_LINK_HOME_A:-$HOME/.tako-linkA}"
HOME_B="${TAKO_LINK_HOME_B:-$HOME/.tako-linkB}"
RUN="link$$x$(date +%s)"
for home in "$HOME_A" "$HOME_B"; do
  case "$home" in "$HOME/.tako"|"$HOME/.hyperterm"|"$HOME/.tako-dev"|"$HOME"|/) echo "refusing HT_HOME $home"; exit 2 ;; esac
done
unset HT_SOCKET HT_SESSION_ID HT_LABEL HT_HOOK_TOKEN HT_CHANNELS HT_MCP_EAGER HT_PORT HT_HOME

PASSED=0; FAILED=0; FAILURES=()
pass() { echo "PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL  $1${2:+ — $2}"; FAILED=$((FAILED + 1)); FAILURES+=("$1"); }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
wait_until() { local t=$1; shift; for _ in $(seq 1 $((t * 5))); do "$@" && return 0; sleep 0.2; done; return 1; }

hta() { HT_HOME="$HOME_A" "$HT" "$@"; }
htb() { HT_HOME="$HOME_B" "$HT" "$@"; }
# status A|B 'python expression over s (the parsed `ht link status`)': succeeds when it's truthy,
# printing it unless it's a bool. The expressions are this script's own literals.
status() {
  local out
  if [ "$1" = A ]; then out=$(hta link status 2>/dev/null); else out=$(htb link status 2>/dev/null); fi
  [ -n "$out" ] || return 1
  python3 -c 'import json,sys; s=json.loads(sys.argv[1]); v=eval(sys.argv[2]); not isinstance(v,bool) and print(v); sys.exit(0 if v else 1)' "$out" "$2" 2>/dev/null
}

WORK=$(mktemp -d /tmp/tako-link.XXXXXX)
PIDS=()
alive() { kill -0 "$1" 2>/dev/null; }
quit_tako() {
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1).terminate" >/dev/null 2>&1
  for _ in $(seq 1 100); do alive "$1" || return 0; sleep 0.05; done
  return 1
}
# Processes carrying this run's marker in their environment.
marked() { ps -axwwE -o pid=,command= | grep -F " TAKO_E2E_RUN=$RUN" | grep -v grep | awk '{print $1}'; }
cleanup() {
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && alive "$pid" && { quit_tako "$pid" || kill -9 "$pid"; }; done
  sleep 0.5
  marked | xargs kill -9 2>/dev/null
  rm -rf "$WORK" "$HOME_A" "$HOME_B"
}
trap cleanup EXIT

# --- build ---------------------------------------------------------------------------------

if [ "${LINK_BUILD:-1}" = 1 ]; then
  if [ ! -x "$EXE" ] || [ -n "$(find Sources project.yml -newer "$EXE" -print -quit)" ]; then
    echo "building Debug…"
    xcodegen generate >/dev/null
    xcodebuild -project Tako.xcodeproj -scheme Tako -configuration Debug -derivedDataPath build/DerivedData build 2>&1 \
      | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
  fi
fi
[ -x "$EXE" ] || { echo "no Debug build at $APP"; exit 2; }

# --- fixtures ------------------------------------------------------------------------------

rm -rf "$HOME_A" "$HOME_B"; mkdir -p "$HOME_A" "$HOME_B" "$WORK/zdot" "$WORK/fakebin"
cat > "$WORK/zdot/.zshrc" <<EOF
export PATH="$WORK/fakebin:\$PATH"
PS1='%~ %# '
unset HISTFILE
EOF
# Fake Claude Code, as in smoke.sh, but its prompt hook carries the prompt, so Tako can tell the
# user's turns from Tako's and peers'. A line with "!" runs what follows the first "!".
cat > "$WORK/fakebin/claude" <<'EOF'
#!/bin/bash
[ "${FAKE_CLAUDE:-}" = 1 ] || FAKE_CLAUDE=1 exec -a claude /bin/bash "$0" "$@"
HT="${HT_HOME:-$HOME/.tako}/bin/ht"
SID=fake CONFIG=
while [ $# -gt 0 ]; do
  case $1 in --session-id) SID=$2; shift ;; --mcp-config=*) [ -z "$CONFIG" ] && CONFIG=${1#--mcp-config=} ;; esac
  shift
done
hook() { "$HT" hook claude "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name": sys.argv[1], "session_id": sys.argv[2], "cwd": sys.argv[3], **({"prompt": sys.argv[4]} if len(sys.argv) > 4 else {})}))' "$@")" >/dev/null 2>&1; }
servers=0
if [ -n "$CONFIG" ]; then
  server=()
  while IFS= read -r part; do server+=("$part"); done < <(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))["mcpServers"]["tako"]
print("\n".join([s["command"]] + s.get("args", [])))' "$CONFIG")
  pipes=$(mktemp -d); mkfifo "$pipes/in" "$pipes/out"
  ( trap '' HUP; exec "${server[@]}" ) <"$pipes/in" >"$pipes/out" &
  exec 3>"$pipes/in" 4<"$pipes/out"
  rm -rf "$pipes"
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' >&3
  IFS= read -r -t 10 _ <&4 && servers=1
fi
hook SessionStart "$SID" "$PWD"
echo "fake-claude ready ($servers mcp)"
hook Stop "$SID" "$PWD"
while printf '> ' && IFS= read -r line; do
  [ -z "$line" ] && continue
  # The prompt is what precedes the "!" (what a user would have typed); the rest is the test's.
  prompt=$line; case $line in *'!'*) prompt=${line%%!*}; prompt=${prompt% } ;; esac
  hook UserPromptSubmit "$SID" "$PWD" "$prompt"
  case $line in
    *'!'*) eval "${line#*!}" ;;
    *) echo "got: ${line:0:160}" ;;
  esac
  hook Stop "$SID" "$PWD"
done
EOF
chmod +x "$WORK/fakebin/claude"
# An MCP client run inside Sumi's terminal, so Tako traces its calls to Sumi.
cat > "$WORK/mcp_client.py" <<'EOF'
import json, os, subprocess, sys
p = subprocess.Popen([os.path.join(os.environ["HT_HOME"], "bin", "ht"), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
n = 0
def call(method, params=None):
    global n; n += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n, "method": method, "params": params or {}}) + "\n"); p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line: return {}
        m = json.loads(line)
        if m.get("id") == n: return m
out = {"init": call("initialize", {"protocolVersion": "2025-06-18"}), "tools": call("tools/list"), "calls": []}
for name, args in json.load(open(sys.argv[1])):
    r = call("tools/call", {"name": name, "arguments": args}).get("result") or {}
    out["calls"].append({"text": "".join(c.get("text", "") for c in r.get("content", [])), "error": r.get("isError")})
p.stdin.close(); p.wait(5)
json.dump(out, open(sys.argv[2] + ".tmp", "w")); os.rename(sys.argv[2] + ".tmp", sys.argv[2])
EOF
# result FILE INDEX: the text of one call.
result() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["calls"][int(sys.argv[2])]["text"])' "$1" "$2"; }
# mcp A|B PREFIX CALLS_JSON NAME: runs the calls from inside that instance's Sumi in a turn whose
# prompt is PREFIX: "tell Blake: …" is the user's own order, "Tako: " a turn Tako started.
mcp() {
  local who=$1 prefix=$2 name=$4
  printf '%s' "$3" > "$WORK/$name.json"
  if [ "$who" = A ]; then hta send @sumi "${prefix}!python3 $WORK/mcp_client.py $WORK/$name.json $WORK/$name.out" >/dev/null
  else htb send @sumi "${prefix}!python3 $WORK/mcp_client.py $WORK/$name.json $WORK/$name.out" >/dev/null; fi
  wait_until 30 test -s "$WORK/$name.out"
}

# --- launch --------------------------------------------------------------------------------

launch() { # launch HOME PORT
  open -n -g -j --env HT_HOME="$1" --env ZDOTDIR="$WORK/zdot" --env TAKO_E2E_RUN="$RUN" "$APP" --args -browserPort "$2"
  for _ in $(seq 1 100); do HT_HOME="$1" "$HT" ls >/dev/null 2>&1 && break; sleep 0.2; done
  ps -axwwE -o pid=,command= | grep -F "$EXE" | grep -F "HT_HOME=$1 " | grep -F "TAKO_E2E_RUN=$RUN" | awk '{print $1; exit}'
}
echo "== launch A ($HOME_A) and B ($HOME_B), run $RUN"
PID_A=$(launch "$HOME_A" 9461); PIDS+=("$PID_A")
PID_B=$(launch "$HOME_B" 9462); PIDS+=("$PID_B")
check "both instances answer (A $PID_A, B $PID_B)" sh -c "[ -n '$PID_A' ] && [ -n '$PID_B' ] && HT_HOME='$HOME_A' '$HT' ls >/dev/null && HT_HOME='$HOME_B' '$HT' ls >/dev/null"
check "Link is off by default" status A 'not s["enabled"] and s["status"] == "Off"'

hta link name Alex >/dev/null; htb link name Blake >/dev/null
hta link on >/dev/null; htb link on >/dev/null
both_on() { status A 's["status"] == "On"' && status B 's["status"] == "On"'; }
check "Link on: both listening" wait_until 10 both_on
sees() { status "$1" "any(n[\"name\"] == \"$2\" for n in s[\"nearby\"])"; }
if wait_until 15 sees A Blake && wait_until 10 sees B Alex; then pass "Bonjour: each sees the other nearby"
else
  # macOS local-network privacy can keep a Debug build off mDNS (no service registered, no
  # results) until someone allows it. Loopback TCP is exempt, so the rest still runs, over
  # addresses added by hand; Bonjour is reported, not failed, unless LINK_REQUIRE_BONJOUR=1.
  why="discovery A: $(status A 's["discovery"]'), B: $(status B 's["discovery"]')"
  if [ "${LINK_REQUIRE_BONJOUR:-0}" = 1 ]; then fail "Bonjour: each sees the other nearby" "$why"; exit 1; fi
  echo "WARN  Bonjour: neither found the other ($why); is local-network access allowed for the Debug app? Using loopback."
  hta link add Blake "$(status B 's["fingerprint"]')" "127.0.0.1:$(status B 's["port"]')" >/dev/null
  htb link add Alex "$(status A 's["fingerprint"]')" "127.0.0.1:$(status A 's["port"]')" >/dev/null
  both_added() { sees A Blake && sees B Alex; }
  check "loopback: each has the other nearby (ht link add)" both_added || exit 1
fi

echo "== pairing"
hta link pair Blake >/dev/null
both_comparing() { status A 's["pairing"] and s["pairing"]["phase"] == "comparing"' && status B 's["pairing"] and s["pairing"]["phase"] == "comparing"'; }
check "both show a code to compare" wait_until 10 both_comparing
CODE_A=$(status A 's["pairing"]["code"]'); CODE_B=$(status B 's["pairing"]["code"]')
check "the codes match ($CODE_A = $CODE_B), six digits" sh -c "[ '$CODE_A' = '$CODE_B' ] && echo '$CODE_A' | grep -qE '^[0-9]{6}$'"
check "B's side is marked incoming" status B 's["pairing"]["incoming"]'
check "A confirms" hta link confirm
sleep 1
check "  … one confirm doesn't pair: A waits for B" status A 's["pairing"]["phase"] == "waiting" and not s["peers"]'
htb link confirm >/dev/null
paired() { status A 'any(p["name"] == "Blake" for p in s["peers"])' && status B 'any(p["name"] == "Alex" for p in s["peers"])'; }
check "both confirmed: each stores the other" wait_until 10 paired
check "peers persist in link.json (0600), key in link-key (0600)" sh -c "grep -q Blake '$HOME_A/link.json' && [ \$(stat -f %Lp '$HOME_A/link-key') = 600 ] && [ \$(stat -f %Lp '$HOME_A/link.json') = 600 ]"

echo "== Sumis"
hta sumi >/dev/null; htb sumi >/dev/null
sumis_ready() { hta read @sumi 2>/dev/null | grep -q 'fake-claude ready (1 mcp)' && htb read @sumi 2>/dev/null | grep -q 'fake-claude ready (1 mcp)'; }
check "both Sumis up with their MCP server" wait_until 30 sumis_ready

# A's user tells A's Sumi what to send, in their own words: that one message goes at once.
mcp A "tell Blake: hi from Alex's Sumi " '[["peer", {"action": "list"}],
 ["peer", {"action": "send", "peer": "Blake", "text": "hi from Alex'"'"'s Sumi"}],
 ["peer", {"action": "send", "peer": "Blake", "text": "hi from Alex'"'"'s Sumi"}],
 ["peer", {"action": "send", "peer": "Blake", "text": "here: ghp_abcdefghijklmnopqrstuvwxyz0123"}],
 ["peer", {"action": "send", "peer": "Bla", "text": "hi"}]]' a1
call() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["calls"][int(sys.argv[2])]["text"])' "$WORK/$1.out" "$2"; }
call_has() { call "$1" "$2" | grep -qF -- "$3"; }
check "peer tool listed for Sumi" python3 -c "import json,sys; o=json.load(open('$WORK/a1.out')); sys.exit(0 if any(t['name']=='peer' for t in o['tools']['result']['tools']) else 1)"
check "peer list: Blake online" call_has a1 0 "- Blake: online"
check "\"tell Blake: …\" in the user's prompt: sent at once" [ "$(call a1 1)" = "sent to Blake" ]
check "the same line can't send twice: the second waits for approval" call_has a1 2 "awaiting the user's approval"
check "a token is blocked before sending" call_has a1 3 "blocked: it looks like it contains a GitHub token"
check "a peer name must match exactly" call_has a1 4 "no paired peer named Bla"
APPROVAL_A=$(status A 's["approvals"][0]["id"]')
check "A's user denies the second: nothing sent" hta link deny "$APPROVAL_A"
mcp A "ask Blake: what is @api working on? " '[["peer", {"action": "ask", "peer": "blake", "question": "what is @api working on?"}]]' a1b
check "\"ask Blake: …\": the ask goes at once, with a request id" call_has a1b 0 "request q-"

got_both() { status B 'any(i["kind"] == "chat" and i["incoming"] for i in s["inbox"]) and any(i["kind"] == "ask" and i["incoming"] for i in s["inbox"])'; }
check "B received the chat and the ask" wait_until 10 got_both
one_chat() { status B 'len([i for i in s["inbox"] if i["kind"] == "chat"]) == 1'; }
check "  … and only one chat (the denied copy never left)" one_chat
check "B's Sumi got them as <peer-message>" wait_until 10 sh -c "HT_HOME='$HOME_B' '$HT' read @sumi -n 80 | grep -q 'peer-message from=\"Alex\" kind=\"ask\"'"
REQ=$(status B '[i["request_id"] for i in s["inbox"] if i["kind"] == "ask"][0]')
check "events.jsonl logs peer, kind and size, never the text" sh -c "grep -q '\"kind\":\"link\"' '$HOME_B/events.jsonl' && grep '\"kind\":\"link\"' '$HOME_B/events.jsonl' | grep -q '\"message\":\"ask\"' && ! grep -q 'working on' '$HOME_B'/events*.jsonl && ! grep -q 'working on' '$HOME_A'/events*.jsonl"

# B's Sumi answers in a turn Tako started (not B's user): it waits for B's approval.
mcp B "Tako: " '[["peer", {"action": "answer", "request_id": "'"$REQ"'", "text": "@api is refactoring auth"}],
 ["peer", {"action": "list"}]]' b1
check "answer outside the user's turn awaits approval" call_has b1 0 "awaiting the user's approval"
check "  … shown to B's user with the exact text" status B 'len(s["approvals"]) == 1 and s["approvals"][0]["text"] == "@api is refactoring auth"'
check "  … and nothing reached A yet" status A 'not any(i["kind"] == "answer" for i in s["inbox"])'
APPROVAL=$(status B 's["approvals"][0]["id"]')
htb link approve "$APPROVAL" "@api is refactoring auth (2 files left)" >/dev/null
answered() { status A 'any(i["kind"] == "answer" and i["incoming"] and i["text"] == "@api is refactoring auth (2 files left)" for i in s["inbox"])'; }
check "B's user approves (edited): A receives the answer" wait_until 10 answered
check "A's Sumi got the answer as <peer-message>" wait_until 10 sh -c "HT_HOME='$HOME_A' '$HT' read @sumi -n 80 | grep -q 'kind=\"answer\" request_id=\"q-'"
check "B's Sumi heard the approval" wait_until 10 sh -c "HT_HOME='$HOME_B' '$HT' read @sumi -n 80 | grep -q 'the user approved your answer to Alex (with edits)'"

echo "== unpair"
htb link unpair Alex >/dev/null
mcp A "tell Blake: still there? " '[["peer", {"action": "send", "peer": "Blake", "text": "still there?"}]]' a2
check "after B unpairs, A's message is refused by B" call_has a2 0 "not sent"
check "B's inbox didn't get it" status B 'not any(i["text"] == "still there?" for i in s["inbox"])'

hta link off >/dev/null
check "Link off: stops listening" status A 's["status"] == "Off" and not s["nearby"]'

echo "== quit"
for pid in "${PIDS[@]}"; do quit_tako "$pid" || kill -9 "$pid"; done
PIDS=()
sleep 0.5
left=$(marked | wc -l | tr -d ' ')
check "quit: nothing of this run left ($left)" [ "$left" = 0 ]

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" = 0 ] || { printf '  %s\n' "${FAILURES[@]}"; exit 1; }
