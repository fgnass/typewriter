#!/bin/zsh
# Builds Typewriter.app into ./build
set -euo pipefail
cd "${0:A:h}"
swift build -c release
APP=build/Typewriter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Typewriter "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/Fin "$APP/Contents/Resources/Fin"
# All recorded sound sets; the user picks one in the settings.
for set in Resources/Sounds-*; do cp -R "$set" "$APP/Contents/Resources/"; done
IDENTITY="${TYPEWRITER_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier com.fgnass.typewriter "$APP"
echo "Built $APP"
