#!/bin/zsh
# Baut Kompass.app. Aufruf:
#   ./build.sh           → build/Kompass.app
#   ./build.sh install   → zusätzlich nach /Applications kopieren
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Kompass.app"
ICONSET="build/AppIcon.iconset"

echo "▸ Kompiliere (Release) …"
swift build -c release --arch arm64

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "▸ Erzeuge App-Icon …"
  mkdir -p "$ICONSET"
  swift Scripts/make_icon.swift build/icon_1024.png >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

echo "▸ Erstelle App-Bundle …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Kompass "$APP/Contents/MacOS/Kompass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ Signiere (ad hoc) …"
codesign --force --sign - --timestamp=none "$APP"

if [[ "${1:-}" == "install" ]]; then
  echo "▸ Installiere nach /Applications …"
  # Laufende App sauber beenden (speichert Daten), notfalls hart
  osascript -e 'tell application "Kompass" to quit' 2>/dev/null || true
  for i in 1 2 3 4 5; do pgrep -x Kompass >/dev/null || break; sleep 1; done
  pkill -x Kompass 2>/dev/null || true
  rm -rf /Applications/Kompass.app
  cp -R "$APP" /Applications/Kompass.app
  echo "✓ Installiert: /Applications/Kompass.app"
else
  echo "✓ Fertig: $APP"
fi
