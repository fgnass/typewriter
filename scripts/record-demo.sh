#!/bin/zsh
# Records the website video: a reply in a mail client mock-up, written on the page and inserted.
#   scripts/record-demo.sh out.mov
# The app shows demo/mail.html full screen in front of everything (TYPEWRITER_STAGE), so the recording
# contains nothing from the real screen. Needs the installed app (./build.sh install) and the screen
# recording permission for the terminal. The screen is busy for about half a minute.
set -euo pipefail
cd "${0:A:h}/.."
OUT="${1:-demo.mov}"
APP=~/Applications/Typewriter.app/Contents/MacOS/Typewriter

[[ -f demo/wallpaper.png ]] || swift scripts/make-wallpaper.swift demo/wallpaper.png
pkill -x Typewriter 2>/dev/null || true
sleep 0.5
TYPEWRITER_STAGE="$PWD/demo/mail.html" TYPEWRITER_WALLPAPER="$PWD/demo/wallpaper.png" TYPEWRITER_APPNAME="Mail" \
TYPEWRITER_SCRIPT=$'Dear Ada,\n\ndo not cut a single line. Your notes are better than the paper itself.\n\nCharles' \
  "$APP" >/dev/null 2>&1 &
sleep 1.5

rm -f "$OUT"
# ffmpeg with the hardware encoder drops fewer frames than screencapture.
ffmpeg -v error -y -f avfoundation -framerate 60 -capture_cursor 0 -i "Capture screen 0:none" -t 33 \
  -c:v h264_videotoolbox -b:v 60M -pix_fmt yuv420p "$OUT"

pkill -x Typewriter 2>/dev/null || true
open ~/Applications/Typewriter.app
echo "Wrote $OUT"
# For the website (the delogo filter hides the recording indicator in the menu bar):
#   ffmpeg -i demo.mov -an -vf "delogo=x=2846:y=3:w=26:h=26,scale=1792:1120:flags=lanczos" -fps_mode cfr -r 60 \
#     -c:v libx264 -pix_fmt yuv420p -crf 23 -preset slow -movflags +faststart docs/video/demo.mp4
