#!/bin/sh
# Build and (re)launch the debug app.
set -e
cd "$(dirname "$0")/.."
# A worktree has no Signing.local.xcconfig (it's ignored): take the main checkout's, so this build
# signs as the same identity and keeps the folder access already allowed.
MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
if [ ! -f Signing.local.xcconfig ] && [ -f "$MAIN/Signing.local.xcconfig" ]; then
  cp "$MAIN/Signing.local.xcconfig" .
fi
xcodegen generate >/dev/null
xcodebuild -project Tako.xcodeproj -scheme Tako -configuration "${CONFIG:-Debug}" \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|warning: .*Tako|BUILD (SUCCEEDED|FAILED)" | sort -u
APP="$PWD/build/DerivedData/Build/Products/${CONFIG:-Debug}/Tako.app"
PID=$(pgrep -f "$APP/Contents/MacOS/Tako" || true)
if [ -n "$PID" ]; then kill "$PID"; sleep 1.5; fi
# Debug runs beside the installed app with its own data (~/.tako-dev), so iterating here
# never restarts your real sessions. A dev folder from before the rename moves over once.
if [ ! -e "$HOME/.tako-dev" ] && [ -d "$HOME/.hyperterm-dev" ] && [ ! -L "$HOME/.hyperterm-dev" ]; then
  mv "$HOME/.hyperterm-dev" "$HOME/.tako-dev" && ln -s "$HOME/.tako-dev" "$HOME/.hyperterm-dev"
fi
if [ "${CONFIG:-Debug}" = Debug ]; then open -n --env HT_HOME="$HOME/.tako-dev" "$APP"; else open "$APP"; fi
