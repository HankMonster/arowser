#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

INSTALL_DIR="${AROWSER_INSTALL_DIR:-$HOME/Applications}"
APP="$INSTALL_DIR/arowser.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc not found; install Xcode Command Line Tools first" >&2
  exit 1
}

echo "Compiling arowser..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -swift-version 5 -parse-as-library -O \
  -o "$TMP/arowser" \
  Arowser.swift \
  -framework AppKit -framework WebKit

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/arowser" "$APP/Contents/MacOS/arowser"
cp Info.plist "$APP/Contents/Info.plist"
# App icon (assets/icon/arowser.icns; CFBundleIconFile in Info.plist).
cp assets/icon/arowser.icns "$APP/Contents/Resources/arowser.icns"
# Menu bar status item glyph (template image, black + alpha).
cp assets/icon/statusbar-template.png "$APP/Contents/Resources/statusbar-template.png"
cp assets/icon/statusbar-template-legacy.png "$APP/Contents/Resources/statusbar-template-legacy.png"

codesign --force --sign - "$APP" >/dev/null
"$LSREGISTER" -f "$APP" || true

mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/bin/arowser" "$HOME/.local/bin/arowser"
ln -sf "$PWD/bin/arowser-watch" "$HOME/.local/bin/arowser-watch"

echo "Installed: $APP"
echo "CLI:       $HOME/.local/bin/arowser"
echo "Watcher:   $HOME/.local/bin/arowser-watch"
echo
echo "Smoke test:"
echo "  id=\$(arowser open https://example.com --title demo)"
echo "  arowser show \"\$id\" https://example.org"
echo "  arowser list"
echo "  arowser close \"\$id\""
