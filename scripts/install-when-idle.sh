#!/bin/sh
# Waits until every agent in the running Tako is idle (no turn, no subagents, nothing waiting
# on the user) for three checks in a row, then runs scripts/install.sh. Meant to run outside
# Tako's process tree (e.g. via `launchctl submit`), so quitting Tako can't kill it midway.
# Log: ~/tako-install.log. Gives up without installing after MAX_WAIT seconds.
cd "$(dirname "$0")/.." || exit 0
LOG="$HOME/tako-install.log"
HT="$HOME/.hyperterm/bin/ht"
[ -x "$HT" ] || HT="$HOME/.tako/bin/ht"
MAX_WAIT=${MAX_WAIT:-21600}
JOB=${JOB_LABEL:-}

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
finish() { [ -n "$JOB" ] && launchctl remove "$JOB" 2>/dev/null; exit 0; }

# Prints the agents that are still busy, one per line; nothing when all are idle.
busy() {
  "$HT" ls --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    sessions = json.load(sys.stdin)
except Exception:
    print("(Tako not answering)"); sys.exit()
for s in sessions:
    if s.get("kind") not in ("claude", "codex"):
        continue
    if s.get("state") != "idle" or s.get("subagents", 0):
        print("@%s %s%s" % (s.get("label"), s.get("state"), " +subagents" if s.get("subagents", 0) else ""))
'
}

log "waiting for every agent to be idle (up to $((MAX_WAIT / 3600)) h)"
calm=0; waited=0; last=""
while [ "$calm" -lt 3 ]; do
  now=$(busy)
  if [ -z "$now" ]; then calm=$((calm + 1)); else calm=0; fi
  [ "$now" != "$last" ] && [ -n "$now" ] && log "busy: $(echo "$now" | tr '\n' ' ')"
  last=$now
  if [ "$waited" -ge "$MAX_WAIT" ]; then log "gave up waiting; nothing installed"; finish; fi
  sleep 30; waited=$((waited + 30))
done

log "all idle; installing"
if scripts/install.sh >> "$LOG" 2>&1; then
  sleep 20
  log "ht doctor after install:"
  "$HOME/.tako/bin/ht" doctor >> "$LOG" 2>&1 || log "(ht doctor didn't answer yet; run it yourself)"
else
  log "install.sh failed; the old Tako was left as it was if the failure came before quitting"
fi
finish
