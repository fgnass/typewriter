#!/bin/sh
# Installs Typewriter into ~/Applications.
#   curl -fsSL https://typewriter.gnass.buzz/install.sh | sh
#
# A download with curl gets no quarantine flag, so macOS opens the app without
# the "unidentified developer" warning.
#
# The new app is unpacked and checked first. The installed app is replaced only
# when the check passes, and it comes back if the replacement fails.
set -eu

URL="${TYPEWRITER_URL:-https://github.com/fgnass/typewriter/releases/latest/download/Typewriter.zip}"
DEST="$HOME/Applications"
APP="$DEST/Typewriter.app"
BUNDLE_ID="com.fgnass.typewriter"
TMP="$(mktemp -d)"
# The backup of the old app is removed only after a successful install or restore (both remove
# or move it). If it is still there at the exit, something failed: keep it and tell where it is.
cleanup() {
  if [ -e "$TMP/old.app" ]; then
    echo "Your previous Typewriter is kept in $TMP/old.app. To restore it, replace $APP with it." >&2
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

fail() { echo "Error: $*" >&2; exit 1; }

[ "$(uname -m)" = arm64 ] || fail "Typewriter needs a Mac with Apple silicon."

echo "Downloading Typewriter…"
curl -fsSL "$URL" -o "$TMP/Typewriter.zip" || fail "The download failed."

mkdir "$TMP/new"
ditto -x -k "$TMP/Typewriter.zip" "$TMP/new" || fail "The download is not a valid archive."
NEW="$TMP/new/Typewriter.app"
[ -x "$NEW/Contents/MacOS/Typewriter" ] || fail "The archive does not contain Typewriter.app."
[ "$(defaults read "$NEW/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$BUNDLE_ID" ] \
  || fail "The archive contains an unexpected app."
lipo -archs "$NEW/Contents/MacOS/Typewriter" | grep -qw arm64 || fail "The app is not built for Apple silicon."
codesign --verify --deep --strict "$NEW" 2>/dev/null || fail "The signature of the app is not valid."

# Ask a running Typewriter to quit, and wait for it. It does not get killed: if a page
# is open, the app copies its text to the clipboard before it quits.
if pgrep -x Typewriter >/dev/null; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  i=0
  while pgrep -x Typewriter >/dev/null; do
    i=$((i + 1))
    [ "$i" -le 50 ] || fail "Typewriter is still running. Quit it from the menu bar and try again."
    sleep 0.1
  done
fi

mkdir -p "$DEST"
if [ -e "$APP" ]; then
  mv "$APP" "$TMP/old.app"
fi
if ! mv "$NEW" "$APP"; then
  rm -rf "$APP"
  if [ -e "$TMP/old.app" ] && mv "$TMP/old.app" "$APP"; then
    fail "Could not install to $APP. The previous version is unchanged."
  fi
  fail "Could not install to $APP."
fi
rm -rf "$TMP/old.app"

echo "Installed to $APP"
echo "Look for the T in the menu bar. Allow Accessibility when macOS asks, so Typewriter can insert your text."
open "$APP"
