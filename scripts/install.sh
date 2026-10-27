#!/bin/sh
# Builds an optimized Release and installs it to /Applications/Tako.app.
# Running sessions keep going: the new app restores them on launch.
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
# A pipe would hide xcodebuild's exit status from set -e, so keep the log in a file and check it.
BUILD_LOG=$(mktemp)
if ! xcodebuild -project Tako.xcodeproj -scheme Tako -configuration Release \
  -derivedDataPath build/DerivedData build >"$BUILD_LOG" 2>&1; then
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$BUILD_LOG" | sort -u || true
  rm -f "$BUILD_LOG"
  echo "Build failed; nothing was quit or replaced."
  exit 1
fi
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$BUILD_LOG" | sort -u || true
rm -f "$BUILD_LOG"
# macOS's App Management protection can stop this terminal from replacing an app in
# /Applications. Check before quitting anything, so a refused copy never leaves you with no app.
for OLD in /Applications/Tako.app /Applications/Kuronami.app; do
  if [ -e "$OLD" ] && ! chmod u+w "$OLD/Contents" 2>/dev/null; then
    echo "macOS won't let this terminal replace $OLD."
    echo "Allow it in System Settings > Privacy & Security > App Management (turn on your terminal app),"
    echo "then run scripts/install.sh again. Tako was left running."
    exit 1
  fi
done
# Stops every running copy, wherever it lives (/Applications, ~/Applications, build/DerivedData, a worktree) and under the
# old names (Kuronami.app, Hyperterm.app), which share this app's data; otherwise the new app hands off to it and quits.
# Matches only the app's own executable as the command (args allowed), not the ht helper or an editor with the path in args.
PIDS=$(pgrep -f "^/([^ ]*/)?(Tako|Kuronami|Hyperterm)\.app/Contents/MacOS/(Tako|Kuronami|Hyperterm)( |\$)" || true)
for PID in $PIDS; do kill "$PID"; done
# Wait for them to really exit (Chromium makes shutdown take a few seconds): a new copy that
# finds the old one still answering its socket hands off to it and quits.
for _ in $(seq 1 40); do
  STILL=""
  for PID in $PIDS; do kill -0 "$PID" 2>/dev/null && STILL=1; done
  [ -z "$STILL" ] && break
  sleep 0.25
done
rm -rf /Applications/Tako.app /Applications/Kuronami.app /Applications/Hyperterm.app
if cp -R build/DerivedData/Build/Products/Release/Tako.app /Applications/Tako.app 2>/dev/null; then
  open /Applications/Tako.app
  echo "Installed /Applications/Tako.app"
else
  # The old app is already gone; run the new build from where it was built rather than nothing.
  open build/DerivedData/Build/Products/Release/Tako.app
  echo "Couldn't copy into /Applications; opened the new build from build/ instead."
fi
