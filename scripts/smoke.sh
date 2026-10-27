#!/bin/bash
# End-to-end smoke test of the Debug app: launches it hidden beside the installed Tako with its
# own data folder, drives `ht` and the MCP server, quits, and checks that nothing it started is
# left running. Prints one PASS/FAIL line per check; exits non-zero if any failed.
#
#   scripts/smoke.sh               build if sources changed, then run every check
#   SMOKE_BUILD=0 scripts/smoke.sh skip the build
#   SMOKE_KILL=0 / SMOKE_MIGRATION=0  skip the parent-death / ~/.hyperterm migration checks
#
# Safety: `ht` is pointed at $HT_HOME's socket (the session variables of a surrounding Tako are
# dropped), and only this run's processes are ever signalled: ones carrying TAKO_E2E_RUN=<run id>,
# descendants of its own Tako pid, or this script's fixture commands. The installed app, ~/.tako
# and ~/.hyperterm are never touched; the migration check runs against a throwaway HOME.
#
# Debugging: SMOKE_DIRECT=dir runs the app binary directly (log and exit status in dir);
# SMOKE_SAMPLE=dir profiles each quit with `sample`.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/DerivedData/Build/Products/Debug/Tako.app"
EXE="$APP/Contents/MacOS/Tako"
HT="$APP/Contents/Resources/bin/ht"
E2E_HOME="${TAKO_E2E_HOME:-$HOME/.tako-e2e}"
# Never the installed app's DevTools port (9339).
BROWSER_PORT="${TAKO_E2E_BROWSER_PORT:-9447}"
RUN="e2e$$x$(date +%s)"

case "$E2E_HOME" in
  "$HOME/.tako"|"$HOME/.hyperterm"|"$HOME/.tako-dev"|"$HOME/.tako-mem"|"$HOME"|/) echo "refusing HT_HOME $E2E_HOME"; exit 2 ;;
esac

# This script may run inside a Tako terminal: its session variables would point `ht` at the
# installed app's socket.
unset HT_SOCKET HT_SESSION_ID HT_LABEL HT_HOOK_TOKEN HT_CHANNELS HT_MCP_EAGER HT_PORT
export HT_HOME="$E2E_HOME"

PASSED=0; FAILED=0; FAILURES=()
pass() { echo "PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL  $1${2:+ — $2}"; FAILED=$((FAILED + 1)); FAILURES+=("$1"); }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
now() { python3 -c 'import time; print(time.time())'; }
elapsed() { python3 -c "print(round($(now) - $1, 2))"; }

# Short: socket paths must fit in 104 bytes.
WORK=$(mktemp -d /tmp/tako-e2e.XXXXXX)
TAKO_PID=""

# --- processes ---------------------------------------------------------------------------

# Which processes are this run's. Three ways, since none sees everything: the marker in a
# process's environment (unreadable for processes under /usr/bin/login, which runs setuid);
# a snapshot of Tako's process tree taken before it quit or died (pid and start time, so a
# reused pid never counts); and commands only this script's fixtures run.
#   procs.py snap PID FILE                     record PID's descendants
#   procs.py ours MARKER [--snap FILE] [--fixtures] [--grep REGEX]
cat > "$WORK/procs.py" <<'EOF'
import json, os, re, subprocess, sys
def table():
    out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,lstart=,command="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        f = line.split(None, 7)
        if len(f) == 8: rows[int(f[0])] = (int(f[1]), " ".join(f[2:7]), f[7])
    return rows
mode, rest = sys.argv[1], sys.argv[2:]
rows = table()
if mode == "snap":
    root, found, grew = int(rest[0]), {int(rest[0])}, True
    while grew:
        grew = False
        for pid, (ppid, _, _) in rows.items():
            if ppid in found and pid not in found: found.add(pid); grew = True
    found.discard(root)
    json.dump([[pid, rows[pid][1]] for pid in found if pid in rows], open(rest[1], "w"))
    sys.exit()
marker, opts = rest[0], rest[1:]
def opt(name): return opts[opts.index(name) + 1] if name in opts else None
hits = set()
envs = subprocess.run(["ps", "-axwwE", "-o", "pid=,command="], capture_output=True, text=True).stdout
env = re.compile(r"\sTAKO_E2E_RUN=" + re.escape(marker) + r"(\.\S*)?(\s|$)")
for line in envs.splitlines():
    pid, _, full = line.strip().partition(" ")
    pid = int(pid)
    if pid in rows and env.search(" " + full[len(rows[pid][2]):]): hits.add(pid)
if opt("--snap") and os.path.exists(opt("--snap")):
    hits |= {pid for pid, start in json.load(open(opt("--snap"))) if pid in rows and rows[pid][1] == start}
if "--fixtures" in opts:
    fixtures = re.compile(os.environ["SMOKE_FIXTURES"])
    hits |= {pid for pid, (_, _, command) in rows.items() if fixtures.search(command)}
me = {os.getpid(), os.getppid()}
for pid in sorted(hits - me):
    if re.search(opt("--grep") or "", rows[pid][2]): print(pid, rows[pid][2][:150])
EOF
procs() { python3 "$WORK/procs.py" "$@"; }
# marked MARKER [REGEX]: by environment only.
marked() { procs ours "$1" ${2:+--grep "$2"}; }
count_marked() { marked "$@" | wc -l | tr -d ' '; }
none_marked() { [ "$(count_marked "$@")" = 0 ]; }
# The Tako pid launched with marker $1.
tako_pid() { marked "$1" | awk -v e="$EXE" 'index($0, e) { print $1; exit }'; }
alive() { kill -0 "$1" 2>/dev/null; }

# Quit through AppKit (NSRunningApplication.terminate), as ⌘Q would, for this pid only.
quit_tako() {
  local pid=$1 start
  start=$(now)
  # SMOKE_SAMPLE=dir: profile the quit (macOS `sample`) to find what holds it up.
  [ -n "${SMOKE_SAMPLE:-}" ] && { sample "$pid" 6 -file "$SMOKE_SAMPLE/quit-$pid.txt" >/dev/null 2>&1 & }
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1).terminate" >/dev/null 2>&1
  for _ in $(seq 1 200); do alive "$pid" || break; sleep 0.05; done
  QUIT_SECS=$(elapsed "$start")
  ! alive "$pid"
}

# SIGKILL whatever still carries marker $1: only after a failed check, so the next run starts clean.
reap_marked() { procs ours "$1" --fixtures | awk '{print $1}' | xargs kill -9 2>/dev/null; true; }

cleanup() {
  [ -n "$TAKO_PID" ] && alive "$TAKO_PID" && { quit_tako "$TAKO_PID" || kill -9 "$TAKO_PID"; }
  sleep 0.5
  reap_marked "$RUN"
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- build -------------------------------------------------------------------------------

if [ "${SMOKE_BUILD:-1}" = 1 ]; then
  if [ ! -x "$EXE" ] || [ -n "$(find Sources project.yml -newer "$EXE" -print -quit)" ]; then
    echo "building Debug…"
    MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
    [ ! -f Signing.local.xcconfig ] && [ -f "$MAIN/Signing.local.xcconfig" ] && cp "$MAIN/Signing.local.xcconfig" .
    xcodegen generate >/dev/null
    xcodebuild -project Tako.xcodeproj -scheme Tako -configuration Debug -derivedDataPath build/DerivedData build 2>&1 \
      | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
  fi
fi
[ -x "$EXE" ] || { echo "no Debug build at $APP"; exit 2; }

# An instance left on this data folder by an earlier run: quit it (it is ours by HT_HOME).
for pid in $(ps -axwwE -o pid=,command= | grep -F "$EXE" | grep -F "HT_HOME=$E2E_HOME " | grep -F " TAKO_E2E_RUN=" | awk '{print $1}'); do
  echo "quitting earlier e2e instance $pid"; quit_tako "$pid" || kill -9 "$pid"
done

# --- fixtures ----------------------------------------------------------------------------

rm -rf "$E2E_HOME"; mkdir -p "$E2E_HOME"
# Near their rotation sizes (hooks.log 2 MB, events.jsonl 1 MB), so this run's writes rotate them.
python3 - "$E2E_HOME" <<'EOF'
import json, sys
home = sys.argv[1]
with open(f"{home}/hooks.log", "w") as f:
    line = "2020-01-01T00:00:00Z claude seed " + "x" * 60 + "\n"
    f.write(line * ((2_000_000 - 200) // len(line)))
with open(f"{home}/events.jsonl", "w") as f:
    line = json.dumps({"t": "2020-01-01T00:00:00Z", "kind": "seed", "text": "x" * 60}) + "\n"
    f.write(line * ((1_000_000 - 40) // len(line)))
EOF

# Sessions' shells read this instead of the user's rc files: a fake `claude` comes first on PATH.
mkdir -p "$WORK/zdot" "$WORK/fakebin" "$WORK/repo"
cat > "$WORK/zdot/.zshrc" <<EOF
export PATH="$WORK/fakebin:\$PATH"
PS1='%~ %# '
unset HISTFILE
EOF
cat > "$WORK/fakebin/claude" <<'EOF'
#!/bin/bash
# Fake Claude Code: no network, no login. Starts the "tako" MCP server named in --mcp-config like
# the real CLI does (so its lifecycle is real), reports hooks with `ht hook`, and runs lines typed
# at it that start with "!" as shell commands. Runs as argv[0] "claude", which is how Tako's
# process inspector recognises the CLI.
[ "${FAKE_CLAUDE:-}" = 1 ] || FAKE_CLAUDE=1 exec -a claude /bin/bash "$0" "$@"
HT="${HT_HOME:-$HOME/.tako}/bin/ht"
SID=fake CONFIG=
while [ $# -gt 0 ]; do
  case $1 in --session-id) SID=$2; shift ;; --mcp-config=*) [ -z "$CONFIG" ] && CONFIG=${1#--mcp-config=} ;; esac
  shift
done
hook() { "$HT" hook claude "{\"hook_event_name\":\"$1\",\"session_id\":\"$SID\",\"cwd\":\"$PWD\"}" >/dev/null 2>&1; }
servers=0
if [ -n "$CONFIG" ]; then
  # "browser" is left out: it would start Chromium.
  server=()
  while IFS= read -r part; do server+=("$part"); done < <(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))["mcpServers"]["tako"]
print("\n".join([s["command"]] + s.get("args", [])))' "$CONFIG")
  # Pipes held open for the agent's life, as the CLI holds its MCP servers' stdio (bash 3.2: no coproc).
  pipes=$(mktemp -d); mkfifo "$pipes/in" "$pipes/out"
  # The server ignores SIGHUP and a stray job keeps its stdin open, so when Tako dies outright
  # only the server's parent-death watch can end it; the job is left for the next launch's sweep.
  ( trap '' HUP; exec "${server[@]}" ) <"$pipes/in" >"$pipes/out" &
  exec 3>"$pipes/in" 4<"$pipes/out"
  rm -rf "$pipes"
  nohup sleep 4646 >/dev/null 2>&1 &
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' >&3
  IFS= read -r -t 10 _ <&4 && servers=1
fi
hook SessionStart
echo "fake-claude ready ($servers mcp)"
hook Stop
while printf '> ' && IFS= read -r line; do
  case $line in
    '!'*) hook UserPromptSubmit; eval "${line#!}"; hook Stop ;;
    '') ;;
    *) hook UserPromptSubmit; echo "got: $line"; hook Stop ;;
  esac
done
EOF
chmod +x "$WORK/fakebin/claude"
(cd "$WORK/repo" && git init -q && echo one > a.txt && git add . && git -c user.name=e2e -c user.email=e2e@localhost commit -qm init && echo two >> a.txt)

# An MCP client run from inside the fake agent's terminal, so Tako traces it to an agent.
cat > "$WORK/mcp_client.py" <<'EOF'
import json, os, subprocess, sys, time
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
out = {"initialize": call("initialize", {"protocolVersion": "2025-06-18"}), "tools": call("tools/list"), "calls": []}
for name, args in json.load(open(sys.argv[1])):
    t = time.time()
    r = call("tools/call", {"name": name, "arguments": args})
    out["calls"].append({"name": name, "result": r.get("result") or {}, "secs": time.time() - t})
p.stdin.close(); p.wait(5)
json.dump(out, open(sys.argv[2] + ".tmp", "w")); os.rename(sys.argv[2] + ".tmp", sys.argv[2])
EOF
# Judges the client's transcript: one PASS/FAIL line per tool.
cat > "$WORK/mcp_check.py" <<'EOF'
import json, sys
o = json.load(open(sys.argv[1]))
def check(name, ok, detail=""): print(("PASS " if ok else "FAIL ") + "mcp " + name + ("" if ok else f" — {detail}"[:200]))
init = o["initialize"].get("result", {})
check("initialize", init.get("serverInfo", {}).get("name") == "tako" and "tools" in init.get("capabilities", {}), init)
tools = o["tools"].get("result", {}).get("tools", [])
names = {t["name"] for t in tools}
expected = {"list_terminals", "send_message", "read_terminal", "set_status", "rename_terminal", "restart_server",
            "start_agent", "open_in_browser", "start_server", "wait_for", "agent_changes", "team_board",
            "server_logs", "notify_user"}
check("tools/list names (mcp__tako__*)", names == expected, sorted(names ^ expected))
loaded = {t["name"] for t in tools if (t.get("_meta") or {}).get("anthropic/alwaysLoad")}
check("tools/list _meta alwaysLoad", loaded == {"list_terminals", "send_message", "read_terminal", "set_status"}, sorted(loaded))
calls = o["calls"]
def text(i): return "".join(c.get("text", "") for c in calls[i]["result"].get("content", []))
def ok(i): return calls[i]["result"].get("isError") is False
check("list_terminals", ok(0) and all(f"@{l}" in text(0) for l in ["sh1", "web", "fake", "peer"]) and "← you" in text(0), text(0))
check("read_terminal", ok(1) and "Serving HTTP" in text(1), text(1))
check("read_terminal alias label=", ok(2) and "Serving HTTP" in text(2), text(2))
check("send_message alias text=", ok(3) and "@peer" in text(3), text(3))
check("server_logs grep", ok(4) and "Serving HTTP" in text(4) and "cursor" in text(4), text(4))
check("team_board note", ok(5), text(5))
check("team_board claim", ok(6) and "a.txt" in text(6), text(6))
check("team_board read", ok(7) and "smoke note" in text(7) and "a.txt" in text(7), text(7))
check("wait_for short timeout", ok(8) and "timed out" in text(8) and 1.5 < calls[8]["secs"] < 6, (text(8), calls[8]["secs"]))
check("agent_changes on a git repo", ok(9) and "a.txt" in text(9), text(9))
EOF
SERVER_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
# Commands only this run's fixtures run.
export SMOKE_FIXTURES="^sleep (4242|4343|4545|4646)$|http\.server $SERVER_PORT|$E2E_HOME/bin/ht mcp|$WORK/"

# --- launch ------------------------------------------------------------------------------

# Hidden and in the background (-g -j), on its own data folder and browser port.
launch() {
  local marker="$RUN.$1"
  if [ -n "${SMOKE_DIRECT:-}" ]; then
    # Debugging: run the binary directly to keep its log and exit status in $SMOKE_DIRECT.
    ( HT_HOME="$E2E_HOME" ZDOTDIR="$WORK/zdot" TAKO_E2E_RUN="$marker" "$EXE" -browserPort "$BROWSER_PORT" \
        >"$SMOKE_DIRECT/tako-$1.log" 2>&1; echo "exit $?" >>"$SMOKE_DIRECT/tako-$1.log" ) &
  else
    open -n -g -j --env HT_HOME="$E2E_HOME" --env ZDOTDIR="$WORK/zdot" --env TAKO_E2E_RUN="$marker" "$APP" --args -browserPort "$BROWSER_PORT"
  fi
  TAKO_PID=""
  for _ in $(seq 1 100); do
    [ -z "$TAKO_PID" ] && TAKO_PID=$(tako_pid "$marker")
    [ -n "$TAKO_PID" ] && "$HT" ls >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}

# Polls `$@` for up to $1 seconds.
wait_until() { local t=$1; shift; for _ in $(seq 1 $((t * 5))); do "$@" && return 0; sleep 0.2; done; return 1; }
screen_has() { "$HT" read "$1" -n "${3:-40}" 2>/dev/null | grep -qF -- "$2"; }
labels() { "$HT" ls --json | python3 -c 'import json,sys; print(" ".join(sorted(s["label"] for s in json.load(sys.stdin))))'; }
server_up() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SERVER_PORT/" 2>/dev/null | grep -q 200; }
ls_has_port() { "$HT" ls --json | grep -q "$SERVER_PORT"; }

# leftovers_after MARKER NAME [procs options]: fails NAME if any of the run's processes still run.
leftovers_after() {
  local left marker=$1 name=$2
  shift 2
  left=$(procs ours "$marker" "$@")
  if [ -z "$left" ]; then pass "$name"; else fail "$name" "$(echo "$left" | wc -l | tr -d ' ') left: $(echo "$left" | cut -c1-90 | tr '\n' ';')"; fi
}

echo "== launch 1 (run $RUN, HT_HOME $E2E_HOME)"
# `ht` must reach this instance's socket, never the installed app's.
probe=$("$HT" ls 2>&1)
if [[ "$probe" == *"no socket at $E2E_HOME/control.sock"* ]]; then pass "ht targets $E2E_HOME/control.sock"
else fail "ht targets $E2E_HOME/control.sock" "$probe"; exit 1; fi
if launch 1; then pass "launch: control socket answers (pid $TAKO_PID)"; else fail "launch: control socket answers"; exit 1; fi
check "ht ls on a fresh home: no terminals" sh -c "'$HT' ls | grep -q 'no terminals'"

"$HT" new shell @sh1 --cwd "$WORK" >/dev/null
"$HT" new shell @sh2 --cwd "$WORK" >/dev/null
"$HT" new server @web --cwd "$WORK" -- python3 -m http.server "$SERVER_PORT" --bind 127.0.0.1 >/dev/null
"$HT" new claude @fake --cwd "$WORK/repo" >/dev/null
"$HT" new claude @peer --cwd "$WORK/repo" >/dev/null
labels_are() { [ "$(labels 2>/dev/null)" = "$1" ]; }
check "ht new: sh1 sh2 web fake peer listed" labels_are 'fake peer sh1 sh2 web'
check "server session serves on :$SERVER_PORT" wait_until 15 server_up
check "ht ls shows the server's port" wait_until 10 ls_has_port

wait_until 10 screen_has @sh1 '%' >/dev/null
"$HT" send @sh1 'echo smoke-$((6*7))' >/dev/null
if wait_until 10 screen_has @sh1 smoke-42; then pass "ht send/read round trip (shell)"
else fail "ht send/read round trip (shell)" "$("$HT" read @sh1 -n 8 2>&1 | tr '\n' '|' | cut -c1-300)"; fi
check "fake agents up with their MCP server" wait_until 20 sh -c "'$HT' read @fake 2>/dev/null | grep -q 'fake-claude ready (1 mcp)' && '$HT' read @peer 2>/dev/null | grep -q 'fake-claude ready (1 mcp)'"
check "ht doctor answers" sh -c "'$HT' doctor | grep -q 'Tako doctor'"

# MCP, from inside @fake.
cat > "$WORK/calls.json" <<EOF
[["list_terminals", {}],
 ["read_terminal", {"terminal": "@web", "lines": 20}],
 ["read_terminal", {"label": "web", "lines": 20}],
 ["send_message", {"to": "@peer", "text": "hello-from-fake"}],
 ["server_logs", {"terminal": "web", "grep": "Serving"}],
 ["team_board", {"action": "note", "text": "smoke note"}],
 ["team_board", {"action": "claim", "paths": ["a.txt"]}],
 ["team_board", {"action": "read"}],
 ["wait_for", {"terminal": "@web", "pattern": "never-printed-xyz", "timeout": 2}],
 ["agent_changes", {}]]
EOF
"$HT" send @fake "!python3 $WORK/mcp_client.py $WORK/calls.json $WORK/mcp.json" >/dev/null
if wait_until 30 test -s "$WORK/mcp.json"; then
  while IFS= read -r line; do
    case "$line" in PASS*) pass "${line#PASS }";; FAIL*) fail "${line#FAIL }";; esac
  done < <(python3 "$WORK/mcp_check.py" "$WORK/mcp.json")
else
  fail "mcp: client finished" "$("$HT" read @fake -n 15 | tr '\n' ' ' | cut -c1-300)"
fi
check "send_message reached @peer's prompt" wait_until 10 screen_has @peer hello-from-fake

# Hooks (sent by the fake agents) land in hooks.log, and both logs rotated past their caps.
check "hooks.log written" wait_until 5 sh -c "cat '$E2E_HOME'/hooks*.log | grep -v ' seed ' | grep -q ' SessionStart agent='"
check "hooks.log rotated (hooks.1.log)" sh -c "[ -f '$E2E_HOME/hooks.1.log' ] && [ \$(wc -c < '$E2E_HOME/hooks.log') -lt 100000 ]"
check "events.jsonl written" grep -q '"kind":"launch"' "$E2E_HOME/events.jsonl"
check "events.jsonl rotated (events.1.jsonl)" sh -c "[ -f '$E2E_HOME/events.1.jsonl' ] && [ \$(wc -c < '$E2E_HOME/events.jsonl') -lt 100000 ]"

# Background jobs that left their shell: closing or quitting must still stop them.
"$HT" send @sh2 'sleep 4242 &!' >/dev/null
"$HT" send @sh1 'nohup sleep 4343 >/dev/null 2>&1 &!' >/dev/null
check "background jobs started" wait_until 5 sh -c "pgrep -fx 'sleep 4242' >/dev/null && pgrep -fx 'sleep 4343' >/dev/null"
sleep 6 # one inspector poll (2.5 s; 5 s while Tako is in the background) records them
"$HT" close @sh2 >/dev/null
check "ht close: @sh2 gone from ht ls" wait_until 5 sh -c "! '$HT' ls | grep -q '@sh2'"
job_4242_gone() { [ -z "$(procs ours "$RUN.1" --fixtures --grep '^sleep 4242$')" ]; }
check "ht close: its disowned job stopped" wait_until 5 job_4242_gone

check "ht mcp servers running under the agents" [ "$(count_marked "$RUN.1" 'bin/ht mcp$')" -ge 2 ]

# A working agent would make quit ask "Quit Tako?" first (a dialog, even when hidden).
at_rest() { ! "$HT" ls --json | grep -q '"state" : "working"'; }
check "every session at rest before quit" wait_until 10 at_rest

echo "== quit 1"
procs snap "$TAKO_PID" "$WORK/snap1"
check "process snapshot has the sessions' shells" [ "$(python3 -c "import json; print(len(json.load(open('$WORK/snap1'))))")" -ge 8 ]
if quit_tako "$TAKO_PID"; then
  if python3 -c "import sys; sys.exit(0 if $QUIT_SECS < 3 else 1)"; then pass "quit in ${QUIT_SECS}s (< 3 s)"; else fail "quit in ${QUIT_SECS}s (< 3 s)"; fi
else
  fail "quit" "still running after ${QUIT_SECS}s"; kill -9 "$TAKO_PID"
fi
sleep 0.5
leftovers_after "$RUN.1" "quit: no shells, server, agents, ht mcp or jobs left" --snap "$WORK/snap1" --fixtures

echo "== launch 2 (restore)"
if launch 2; then pass "relaunch"; else fail "relaunch"; exit 1; fi
check "restore: same sessions, no duplicates" wait_until 10 labels_are 'fake peer sh1 web'
check "restore: server serves again" wait_until 15 server_up
check "restore: agents resumed with MCP" wait_until 20 sh -c "'$HT' read @fake 2>/dev/null | grep -q 'fake-claude ready (1 mcp)'"
launches=$(cat "$E2E_HOME"/events*.jsonl | grep -c '"kind":"launch"')
check "events.jsonl: one launch line per launch ($launches)" [ "$launches" = 2 ]
check "clean quit: launch sweep found nothing" sh -c "! cat '$E2E_HOME'/events*.jsonl | grep -q '\"kind\":\"sweep\"'"
check "ht doctor counts the launches" sh -c "'$HT' doctor | grep -q 'launches: 2'"

if [ "${SMOKE_KILL:-1}" = 1 ]; then
  echo "== SIGKILL (parent death)"
  wait_until 20 sh -c "'$HT' read @peer 2>/dev/null | grep -q 'fake-claude ready (1 mcp)'" >/dev/null
  # A job in a shell whose processes all hide their environment (only built-ins ran there).
  "$HT" send @sh1 'nohup sleep 4545 >/dev/null 2>&1 &!' >/dev/null
  sleep 6 # an inspector poll records every session's processes in the ledger
  stray=$(procs ours "$RUN.2" --fixtures --grep '^sleep (4545|4646)$' | wc -l | tr -d ' ')
  procs snap "$TAKO_PID" "$WORK/snap2"
  mcp_count=$(count_marked "$RUN.2" 'bin/ht mcp$')
  kill -9 "$TAKO_PID"
  start=$(now)
  wait_until 8 none_marked "$RUN.2" 'bin/ht mcp$'
  gone=$?
  secs=$(elapsed "$start")
  if [ "$gone" = 0 ] && python3 -c "import sys; sys.exit(0 if $secs <= 5.5 else 1)"; then pass "parent death: $mcp_count ht mcp exited in ${secs}s"; else fail "parent death: ht mcp exited within 5 s" "${secs}s, $mcp_count before"; fi
  survivors=$(procs ours "$RUN.2" --snap "$WORK/snap2" | wc -l | tr -d ' ')
  echo "info  $survivors processes outlived the SIGKILL (the next launch sweeps them)"
  if launch 3; then pass "relaunch after SIGKILL"; else fail "relaunch after SIGKILL"; exit 1; fi
  swept() { [ -z "$(procs ours "$RUN.2" --snap "$WORK/snap2")" ]; }
  check "launch sweep reaped the killed run's processes" wait_until 8 swept
  check "stray jobs outlived the SIGKILL ($stray, to test the sweep)" [ "$stray" -ge 3 ]
  [ "$survivors" -gt 0 ] && check "launch sweep logged in events.jsonl" sh -c "cat '$E2E_HOME'/events*.jsonl | grep '\"kind\":\"sweep\"' | grep -q 'stopped leftover'"
  check "restore after SIGKILL: no duplicates" wait_until 10 labels_are 'fake peer sh1 web'
  check "restore after SIGKILL: server serves again" wait_until 15 server_up
  LAST=3
else
  LAST=2
fi
procs snap "$TAKO_PID" "$WORK/snap$LAST"
quit_tako "$TAKO_PID" || kill -9 "$TAKO_PID"
sleep 0.5
leftovers_after "$RUN.$LAST" "final quit: nothing left" --snap "$WORK/snap$LAST" --fixtures
TAKO_PID=""

if [ "${SMOKE_MIGRATION:-1}" = 1 ]; then
  echo "== ~/.hyperterm → ~/.tako migration (throwaway HOME)"
  FH=$(mktemp -d /tmp/tako-mig.XXXXXX)
  mkdir -p "$FH/.hyperterm"; echo '[]' > "$FH/.hyperterm/sessions.json"; echo keep > "$FH/.hyperterm/marker"
  # CoreFoundation takes the home folder from CFFIXED_USER_HOME, not $HOME. Prove `ht` (same
  # API as the app) resolves into the throwaway home before letting the app run without HT_HOME.
  probe=$(env -u HT_HOME HOME="$FH" CFFIXED_USER_HOME="$FH" "$HT" ls 2>&1)
  if [[ "$probe" == *"$FH/.hyperterm/control.sock"* ]]; then
    # Run directly, not through `open`, so the app gets exactly the environment just proven.
    env -u HT_HOME HOME="$FH" CFFIXED_USER_HOME="$FH" TAKO_E2E_RUN="$RUN.mig" "$EXE" -browserPort "$BROWSER_PORT" >/dev/null 2>&1 &
    TAKO_PID=$!
    check "migration: app answers on the moved folder" wait_until 20 sh -c "[ -S '$FH/.tako/control.sock' ] && env -u HT_HOME HOME='$FH' CFFIXED_USER_HOME='$FH' '$HT' ls >/dev/null 2>&1"
    check "migration: ~/.tako holds the old data" sh -c "[ -d '$FH/.tako' ] && [ ! -L '$FH/.tako' ] && grep -q keep '$FH/.tako/marker'"
    check "migration: ~/.hyperterm is a link to ~/.tako" sh -c "[ -L '$FH/.hyperterm' ] && [ \"\$(readlink '$FH/.hyperterm')\" = '$FH/.tako' ]"
    [ -n "$TAKO_PID" ] && { quit_tako "$TAKO_PID" || kill -9 "$TAKO_PID"; }
    TAKO_PID=""
    leftovers_after "$RUN.mig" "migration: quit leaves nothing"
  else
    fail "migration: throwaway HOME honoured" "$probe"
  fi
  rm -rf "$FH"
fi

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" = 0 ] || { printf '  %s\n' "${FAILURES[@]}"; exit 1; }
