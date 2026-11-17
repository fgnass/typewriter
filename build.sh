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
# Signing: TYPEWRITER_SIGN_IDENTITY (for example a Developer ID for releases), otherwise the local
# "Typewriter Local Signing" certificate if it exists, otherwise ad hoc. A stable identity keeps the
# Accessibility permission across builds.
IDENTITY="${TYPEWRITER_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q "Typewriter Local Signing"; then
    IDENTITY="Typewriter Local Signing"
  else
    IDENTITY="-"
  fi
fi
codesign --force --sign "$IDENTITY" --identifier com.fgnass.typewriter "$APP"
echo "Built $APP"
