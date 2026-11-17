#!/bin/sh
# Installs Typewriter into ~/Applications.
#   curl -fsSL https://typewriter.gnass.buzz/install.sh | sh
#
# A download with curl gets no quarantine flag, so macOS opens the app without
# the "unidentified developer" warning.
set -eu

URL="${TYPEWRITER_URL:-https://github.com/fgnass/typewriter/releases/latest/download/Typewriter.zip}"
DEST="$HOME/Applications"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Typewriter…"
curl -fsSL "$URL" -o "$TMP/Typewriter.zip"

pkill -x Typewriter 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/Typewriter.app"
ditto -x -k "$TMP/Typewriter.zip" "$DEST"

echo "Installed to $DEST/Typewriter.app"
echo "Look for the T in the menu bar. Allow Accessibility when macOS asks, so Typewriter can insert your text."
open "$DEST/Typewriter.app"
