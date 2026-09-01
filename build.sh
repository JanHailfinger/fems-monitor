#!/bin/bash
# Baut FEMS Monitor, signiert ad-hoc und installiert nach /Applications.
set -e
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "xcodegen fehlt: brew install xcodegen"; exit 1; }

echo "→ Xcode-Projekt erzeugen"
xcodegen generate

echo "→ bauen"
xcodebuild -project FEMSMonitor.xcodeproj -scheme FEMSMonitor -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build | grep -E "error:|BUILD" || true

APP="build/Build/Products/Release/FEMSMonitor.app"
[ -d "$APP" ] || { echo "Build fehlgeschlagen"; exit 1; }

echo "→ signieren"
codesign --force --deep --sign - --entitlements Widget/Widget.entitlements \
  "$APP/Contents/PlugIns/FEMSWidget.appex"
codesign --force --sign - --entitlements App/App.entitlements "$APP"

echo "→ installieren"
osascript -e 'tell application "FEMSMonitor" to quit' 2>/dev/null || true
pkill -f FEMSMonitor 2>/dev/null || true
sleep 2
rm -rf /Applications/FEMSMonitor.app
cp -R "$APP" /Applications/
xattr -dr com.apple.quarantine /Applications/FEMSMonitor.app 2>/dev/null || true

open /Applications/FEMSMonitor.app
echo "✓ fertig — Widget über Rechtsklick auf den Desktop hinzufügen"
