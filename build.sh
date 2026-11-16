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
# Sound set: TYPEWRITER_SOUNDS=electric uses Resources/Sounds-electric, otherwise Resources/Sounds.
SOUNDS=Resources/Sounds
if [[ "${TYPEWRITER_SOUNDS:-electric}" == electric && -d Resources/Sounds-electric ]]; then SOUNDS=Resources/Sounds-electric; fi
if [[ -d "$SOUNDS" ]]; then cp -R "$SOUNDS" "$APP/Contents/Resources/Sounds"; fi
echo "Sounds: $SOUNDS"
IDENTITY="${TYPEWRITER_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier com.fgnass.typewriter "$APP"
echo "Built $APP"
