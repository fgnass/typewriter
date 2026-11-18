#!/bin/zsh
# Builds Typewriter.app into ./build
#   ./build.sh           build for this Mac
#   ./build.sh install   also copy it to ~/Applications
#   ./build.sh release   also write build/Typewriter.zip (Apple silicon) for a GitHub release
set -euo pipefail
cd "${0:A:h}"
MODE="${1:-}"

# Always Apple silicon, also when built on an Intel Mac: the release is for Apple silicon only.
ARCH="${TYPEWRITER_ARCH:-arm64}"
swift build -c release --arch "$ARCH"
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/Typewriter"

APP=build/Typewriter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Typewriter"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Fin "$APP/Contents/Resources/Fin"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
# All recorded sound sets; the user picks one in the settings.
for set in Resources/Sounds-*; do cp -R "$set" "$APP/Contents/Resources/"; done

# Signing: TYPEWRITER_SIGN_IDENTITY (for example a Developer ID), otherwise the local
# "Typewriter Local Signing" certificate if it exists, otherwise ad hoc. A stable identity keeps the
# Accessibility permission across builds and updates.
IDENTITY="${TYPEWRITER_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q "Typewriter Local Signing"; then
    IDENTITY="Typewriter Local Signing"
  else
    IDENTITY="-"
  fi
fi
codesign --force --sign "$IDENTITY" --identifier com.fgnass.typewriter "$APP"
echo "Built $APP (signed: $IDENTITY)"

if [[ "$MODE" == install ]]; then
  DEST="$HOME/Applications/Typewriter.app"
  # Ask the app to quit (not kill it): an open page lives only in memory.
  osascript -e 'tell application id "com.fgnass.typewriter" to quit' 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed to $DEST"
fi

if [[ "$MODE" == release ]]; then
  [[ "$(lipo -archs "$APP/Contents/MacOS/Typewriter")" == arm64 ]] || { echo "The release must be arm64" >&2; exit 1; }
  [[ "$IDENTITY" == "-" ]] && echo "Note: ad hoc signature. The app is not notarized; install it with install.sh (curl sets no quarantine flag)."
  rm -f build/Typewriter.zip
  ditto -c -k --keepParent "$APP" build/Typewriter.zip
  echo "Wrote build/Typewriter.zip"
fi
