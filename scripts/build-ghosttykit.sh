#!/bin/sh
# Builds GhosttyKit.xcframework (libghostty, ReleaseFast, arm64) from a pinned Ghostty tag and
# copies it plus Ghostty's version-matched resources (shell integration, terminfo) into the repo.
set -eu

GHOSTTY_TAG="v1.3.1"
ZIG_VERSION="0.15.2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/ghostty"

ZIG="$(command -v zig || true)"
[ -x /opt/homebrew/opt/zig@0.15/bin/zig ] && ZIG=/opt/homebrew/opt/zig@0.15/bin/zig
if [ -z "$ZIG" ] || [ "$("$ZIG" version)" != "$ZIG_VERSION" ]; then
  echo "need zig $ZIG_VERSION (brew install zig@0.15)" >&2
  exit 1
fi

if [ ! -d "$VENDOR" ]; then
  git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty.git "$VENDOR"
fi

(cd "$VENDOR" && "$ZIG" build \
  -Demit-xcframework=true -Dxcframework-target=native \
  -Demit-macos-app=false -Doptimize=ReleaseFast)

rm -rf "$ROOT/GhosttyKit.xcframework" "$ROOT/Resources/ghostty" "$ROOT/Resources/terminfo"
cp -R "$VENDOR/macos/GhosttyKit.xcframework" "$ROOT/GhosttyKit.xcframework"
mkdir -p "$ROOT/Resources/ghostty"
cp -R "$VENDOR/zig-out/share/ghostty/shell-integration" "$VENDOR/zig-out/share/ghostty/themes" "$ROOT/Resources/ghostty/"
cp -R "$VENDOR/zig-out/share/terminfo" "$ROOT/Resources/terminfo"
cp "$ROOT/Resources/tako-defaults.conf" "$ROOT/Resources/tako-style.conf" "$ROOT/Resources/ghostty/"
echo "GhosttyKit ready"
