#!/bin/zsh
# Memory soak: runs a separate Tako instance under simulated agent load and records its
# footprint and heap class counts over time, so growth can be seen and diffed.
#
#   scripts/soak.sh [-a app] [-m minutes] [-n agents] [-r rate] [-o outdir] [-s]
#
#   -a  Tako.app to run (default: this worktree's Release build)
#   -m  minutes to run (default 30); -n steady agents (default 8); -r pace multiplier (default 3)
#   -o  output folder (default /tmp/tako-soak-<time>); -s  MallocStackLogging (for `leaks`)
#
# Nothing here touches the installed app or its data: the instance runs with HT_HOME=~/.tako-mem
# (override with SOAK_HOME), and the fake `claude` (scripts/soak/fake-agent.py) replaces the
# instance's own agent wrapper, so no real agent starts and nothing is billed. Output:
#   footprint.csv  minute, footprint MB and its largest parts, sessions
#   heap-<minute>.txt, vmmap-<minute>.txt   snapshots every SOAK_SNAPSHOT minutes (default 5)
#   heap-diff.txt  the classes that grew most between the first and last snapshot
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/DerivedData/Build/Products/Release/Tako.app"
MINUTES=30 AGENTS=8 RATE=3 STACKS=0
OUT="/tmp/tako-soak-$(date +%H%M%S)"
while getopts "a:m:n:r:o:s" opt; do
  case $opt in
    a) APP=$OPTARG ;; m) MINUTES=$OPTARG ;; n) AGENTS=$OPTARG ;; r) RATE=$OPTARG ;; o) OUT=$OPTARG ;; s) STACKS=1 ;;
    *) sed -n 2,17p "$0"; exit 2 ;;
  esac
done
SNAPSHOT=${SOAK_SNAPSHOT:-5}
export HT_HOME=${SOAK_HOME:-$HOME/.tako-mem}
case "$HT_HOME" in "$HOME/.tako"|"$HOME/.hyperterm"|"$HOME/.tako/"|"$HOME/.hyperterm/") echo "refusing to soak in the live data folder"; exit 1 ;; esac
# Run from inside a Tako terminal, these would point every `ht` at the live app.
unset HT_SOCKET HT_SESSION_ID HT_HOOK_TOKEN HT_LABEL HT_CHANNELS
export SOAK_RATE=$RATE
# HT_SOCKET wins over HT_HOME in `ht`.
[ -z "${HT_SOCKET:-}" ] || { echo "HT_SOCKET still set"; exit 1; }
case "$HT_HOME" in /*) ;; *) echo "HT_HOME must be absolute"; exit 1 ;; esac
HT="$APP/Contents/Resources/bin/ht"
WORK="$OUT/work"
mkdir -p "$OUT" "$WORK" "$HT_HOME"
log() { print -r -- "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/soak.log"; }

# --- launch -------------------------------------------------------------------------------
ENVS=(--env HT_HOME="$HT_HOME")
[ $STACKS = 1 ] && ENVS+=(--env MallocStackLogging=1)
open -n "${ENVS[@]}" "$APP" || exit 1
for _ in {1..60}; do [ -S "$HT_HOME/control.sock" ] && [ -f "$HT_HOME/claude-settings.json" ] && break; sleep 0.5; done
PID=$(pgrep -nf "$APP/Contents/MacOS/Tako")
# Every `ht` below must reach this instance: its pid owns $HT_HOME/control.sock.
lsof -t "$HT_HOME/control.sock" 2>/dev/null | grep -qx "$PID" || { log "control.sock under $HT_HOME isn't pid $PID's"; kill $PID; exit 1; }
[ -n "$PID" ] || { log "Tako didn't start"; exit 1; }
sleep 2
# The instance writes its wrapper at launch; replace it with the fake agent and check it took.
cp "$ROOT/scripts/soak/fake-agent.py" "$HT_HOME/bin/claude" && chmod +x "$HT_HOME/bin/claude"
cmp -s "$ROOT/scripts/soak/fake-agent.py" "$HT_HOME/bin/claude" || { log "fake agent not installed"; kill $PID; exit 1; }
log "Tako pid $PID, HT_HOME=$HT_HOME, out=$OUT, $AGENTS agents, rate $RATE, $MINUTES min"
trap 'log "stopping"; kill $PID 2>/dev/null; pkill -f "$HT_HOME/bin/claude" 2>/dev/null; exit' INT TERM

repo() {  # a small git repo for an agent to edit, so checkpoints and reviews have work to do
  local dir="$WORK/$1"
  [ -d "$dir/.git" ] && { print $dir; return; }
  mkdir -p "$dir/src" && (cd "$dir" && git init -q && for i in {0..6}; do head -c 20000 /dev/urandom | base64 > src/file$i.txt; done \
    && git add -A && git -c user.email=soak@tako -c user.name=soak commit -qm init)
  print $dir
}
ht() { "$HT" "$@" >/dev/null 2>>"$OUT/ht-errors.log"; }

# A file of terminal output for shells to print over and over.
for i in {1..4000}; do print "line $i $(head -c 90 /dev/urandom | base64)"; done > "$WORK/noise.txt"

# --- measuring ----------------------------------------------------------------------------
print "minute,footprint_mb,scrollback_mb,iosurface_mb,gpu_mb,malloc_mb,sessions" > "$OUT/footprint.csv"
sample() {  # dirty MB per footprint category; "scrollback" is libghostty's pages (tag 240)
  local minute=$1
  local row=$(footprint $PID 2>/dev/null | awk '
    function mb(v, u) { return u == "GB" ? v * 1024 : u == "KB" ? v / 1024 : u == "B" ? 0 : v }
    /Footprint:/ { total = mb($5, $6) }
    / app-specific tag 1$/ { pages = mb($1, $2) }
    / IOSurface$/ { surf = mb($1, $2) }
    / IOAccelerator \(graphics\)$/ { gpu = mb($1, $2) }
    / MALLOC_SMALL$| MALLOC_TINY$| MALLOC_MEDIUM$| MALLOC_LARGE$| MALLOC_NANO$/ { heap += mb($1, $2) }
    END { printf "%d,%d,%d,%d,%d", total, pages, surf, gpu, heap }')
  local count=$("$HT" ls --json 2>/dev/null | grep -c '"label"')
  print "$minute,$row,$count" >> "$OUT/footprint.csv"
  log "t=${minute}m footprint,scrollback,iosurface,gpu,malloc MB = $row; sessions=$count"
}
snapshot() {
  heap $PID > "$OUT/heap-$1.txt" 2>/dev/null
  vmmap --summary $PID > "$OUT/vmmap-$1.txt" 2>/dev/null
}

# --- load ---------------------------------------------------------------------------------
for i in $(seq 1 $AGENTS); do ht new claude "@a$i" --cwd "$(repo a$i)"; done
for i in 1 2; do ht new shell "@s$i" --cwd "$WORK" -- "while :; do cat '$WORK/noise.txt'; sleep 2; done"; done
ht new server "@srv" --cwd "$WORK" -- "while :; do date; head -c 3000 /dev/urandom | base64; sleep 0.5; done"

sleep 20
sample 0; snapshot 0
start=$(date +%s) churn=0 last_snapshot=0
while :; do
  now=$(date +%s); minute=$(( (now - start) / 60 ))
  [ $minute -ge $MINUTES ] && break
  churn=$((churn + 1))
  # Sessions come and go: an agent and a shell opened, worked, and closed.
  ht new claude "@c$churn" --cwd "$(repo c$(( churn % 4 )))"
  ht new shell "@t$churn" --cwd "$WORK" -- "cat '$WORK/noise.txt'"
  # Agents message each other; a busy one queues the message until its turn ends.
  for _ in 1 2 3; do
    from=$(( RANDOM % AGENTS + 1 )) to=$(( RANDOM % AGENTS + 1 ))
    HT_SESSION_ID= "$HT" send "@a$to" "message from a$from: $(head -c 600 /dev/urandom | base64)" >/dev/null 2>&1
  done
  ht read "@a$(( RANDOM % AGENTS + 1 ))" -n 200
  ht status "@a1" "soak round $churn"
  sleep $(( 20 / RATE + 4 ))
  ht close "@t$churn"
  [ $churn -gt 1 ] && ht close "@c$(( churn - 1 ))"
  sample $(( ($(date +%s) - start) / 60 ))
  if [ $(( minute - last_snapshot )) -ge $SNAPSHOT ]; then snapshot $minute; last_snapshot=$minute; fi
done
ht close "@c$churn"
sleep 10
sample $MINUTES; snapshot $MINUTES

# --- report -------------------------------------------------------------------------------
python3 -I - "$OUT/heap-0.txt" "$OUT/heap-$MINUTES.txt" > "$OUT/heap-diff.txt" <<'PY'
import re, sys
def counts(path):
    table = {}
    for line in open(path, errors="replace"):
        m = re.match(r"\s+(\d+)\s+(\d+)\s+[\d.]+\s+(.+?)\s{2,}", line)
        if m: table[m.group(3)] = (int(m.group(1)), int(m.group(2)))
    return table
a, b = counts(sys.argv[1]), counts(sys.argv[2])
rows = sorted(((b[k][1] - a.get(k, (0, 0))[1], b[k][0] - a.get(k, (0, 0))[0], k) for k in b), reverse=True)
print(f"{'dBYTES':>12} {'dCOUNT':>8}  CLASS")
for db, dc, k in rows[:60]: print(f"{db:>12} {dc:>8}  {k}")
PY
log "done; growth by class in $OUT/heap-diff.txt"
[ "${SOAK_KEEP:-0}" = 1 ] || { kill $PID; pkill -f "$HT_HOME/bin/claude" 2>/dev/null; }
