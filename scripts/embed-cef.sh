#!/bin/sh
# Embeds Chromium (CEF) into the built Tako.app: the framework plus the five helper apps
# Chromium launches renderers, GPU and utility processes from. Run as an Xcode post-build phase.
#
# The CEF distribution (~130 MB download, ~400 MB extracted) is cached once per version in
# ~/Library/Caches/Hyperterm/cef and copied into each build only when it changed.
# Ported from CefSwift's AppBundler/FrameworkLayout (MIT).
set -eu

CEF_VERSION="154.0.32+g682c378+chromium-154.0.8037.58"
CEF_SHA1="2e9df1077c097e450d30f26804b7c4b1820da4e3"
CEF_NAME="cef_binary_${CEF_VERSION}_macosarm64_minimal"
FRAMEWORK_NAME="Chromium Embedded Framework"

CACHE="$HOME/Library/Caches/Hyperterm/cef"
DIST="$CACHE/$CEF_NAME"
SOURCE_FRAMEWORK="$DIST/Release/$FRAMEWORK_NAME.framework"

prepare_distribution() {
  [ -e "$SOURCE_FRAMEWORK/Versions/Current" ] && return
  mkdir -p "$CACHE"
  ARCHIVE="$CACHE/$CEF_NAME.tar.bz2"
  if [ ! -f "$ARCHIVE" ] || [ "$(shasum -a 1 "$ARCHIVE" | cut -d' ' -f1)" != "$CEF_SHA1" ]; then
    echo "Downloading CEF $CEF_VERSION"
    # The version contains '+', which must be escaped in the URL.
    URL_NAME=$(printf '%s' "$CEF_NAME" | sed 's/+/%2B/g')
    curl -fL --retry 3 -C - -o "$ARCHIVE" "https://cef-builds.spotifycdn.com/$URL_NAME.tar.bz2"
    [ "$(shasum -a 1 "$ARCHIVE" | cut -d' ' -f1)" = "$CEF_SHA1" ] || { echo "error: CEF checksum mismatch"; rm -f "$ARCHIVE"; exit 1; }
  fi
  rm -rf "$DIST" && mkdir -p "$DIST"
  tar -xjf "$ARCHIVE" -C "$DIST" --strip-components=1
  # Distributions ship a flat framework; codesign and current Xcode need the versioned layout.
  mkdir -p "$SOURCE_FRAMEWORK/Versions/A"
  for entry in "$FRAMEWORK_NAME" Libraries Resources; do
    mv "$SOURCE_FRAMEWORK/$entry" "$SOURCE_FRAMEWORK/Versions/A/$entry"
    ln -s "Versions/A/$entry" "$SOURCE_FRAMEWORK/$entry"
  done
  ln -s A "$SOURCE_FRAMEWORK/Versions/Current"
  # The archive is only needed to re-verify; drop it to save disk.
  rm -f "$ARCHIVE"
}

write_helper_plist() { # path name bundle-id
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>${MACOSX_DEPLOYMENT_TARGET:-15.0}</string>
  <key>LSUIElement</key><true/>
  <key>LSFileQuarantineEnabled</key><true/>
  <key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
</dict>
</plist>
PLIST
}

prepare_distribution

APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
FRAMEWORKS="$APP/Contents/Frameworks"
APP_NAME="$EXECUTABLE_NAME"
HELPER_BINARY="$BUILT_PRODUCTS_DIR/TakoHelper"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -n "$IDENTITY" ] || IDENTITY="-"
mkdir -p "$FRAMEWORKS"

# Framework: copy only when the version changed (it is ~400 MB).
DEST_FRAMEWORK="$FRAMEWORKS/$FRAMEWORK_NAME.framework"
if [ "$(cat "$DEST_FRAMEWORK/.cef-version" 2>/dev/null)" != "$CEF_VERSION" ]; then
  rm -rf "$DEST_FRAMEWORK"
  cp -R "$SOURCE_FRAMEWORK" "$DEST_FRAMEWORK"
  codesign --force --timestamp=none --sign "$IDENTITY" "$DEST_FRAMEWORK"
  # Written after signing, at the bundle root where codesign ignores it.
  echo "$CEF_VERSION" > "$DEST_FRAMEWORK/.cef-version"
fi

# Five helpers, same binary. Names are load-bearing: CEF derives them from the main executable.
for SUFFIX in "" " (Alerts)" " (GPU)" " (Plugin)" " (Renderer)"; do
  NAME="$APP_NAME Helper$SUFFIX"
  ID_SUFFIX=$(printf '%s' "$SUFFIX" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')
  BUNDLE_ID="$PRODUCT_BUNDLE_IDENTIFIER.helper${ID_SUFFIX:+.$ID_SUFFIX}"
  HELPER_APP="$FRAMEWORKS/$NAME.app"
  mkdir -p "$HELPER_APP/Contents/MacOS"
  cp -f "$HELPER_BINARY" "$HELPER_APP/Contents/MacOS/$NAME"
  write_helper_plist "$HELPER_APP/Contents/Info.plist" "$NAME" "$BUNDLE_ID"
  codesign --force --timestamp=none --sign "$IDENTITY" "$HELPER_APP"
done
