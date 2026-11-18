# Typewriter

Write anything in any app on your Mac (a mail, a Word document, a form in the
browser, a chat) on a quiet page with nothing else on the screen.

Press ⌥ Space (or any shortcut you choose in the settings) and the main display becomes a sheet of paper. A small carriage moves
as you type, and a warm lamp lights the line. ⌘↩ inserts the text into the field
that had the focus, or copies it to the clipboard. Esc puts the page away; Copy Last Page in the menu brings it back.

Nothing you type is written to disk. Only the last page stays in memory
(menu bar → Copy Last Page). The app makes no network connections.

Optional: Do Not Disturb while the page is open (Settings → Do Not Disturb while
writing). macOS has no public API for Focus, so Typewriter creates a shortcut named
"Typewriter Focus" (Shortcuts asks once to add it) and runs it with `shortcuts run`.
It turns Do Not Disturb off again only if it turned it on itself.

**Website:** https://typewriter.gnass.buzz

## Install

```sh
curl -fsSL https://typewriter.gnass.buzz/install.sh | sh
```

Or download `Typewriter.zip` from the [latest release](https://github.com/fgnass/typewriter/releases/latest).
Requires macOS 13 or later on Apple silicon. Allow Accessibility when macOS asks;
Typewriter needs it to paste into other apps.

## Build

```sh
./build.sh           # build/Typewriter.app
./build.sh install   # also copy to ~/Applications
./build.sh release   # also write build/Typewriter.zip for a GitHub release
swift scripts/make-icon.swift   # regenerate Resources/AppIcon.icns from Resources/Icon/source.png
```

Requires the Xcode Command Line Tools.

Signing: set `TYPEWRITER_SIGN_IDENTITY` to sign with a given identity. Otherwise
`build.sh` uses a certificate named "Typewriter Local Signing" if one is in the
keychain, else ad hoc. A stable identity keeps the Accessibility permission
across builds; with ad hoc signing, macOS asks again after each build.

The website is in `docs/` (GitHub Pages).
