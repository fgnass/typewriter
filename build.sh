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
if [[ -d Resources/Sounds ]]; then cp -R Resources/Sounds "$APP/Contents/Resources/"; fi
IDENTITY="${TYPEWRITER_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier com.fgnass.typewriter "$APP"
echo "Built $APP"
