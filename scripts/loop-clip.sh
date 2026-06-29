#!/bin/bash
# Regenerate the lemon.living "THE LOOP" autoplay video from the real UI.
# Called by `make loop-clip` (after `make build-ui`). Runs the app in --film
# mode (SmokeTestDriver.film walks one issue through its lifecycle, capturing a
# frame per beat to /tmp/lemon-film), then ffmpeg-crossfades the frames into a
# small looping MP4 + a poster frame, committed under docs/img/.
#
# Deterministic + regenerable: re-run whenever the UI changes so the demo never
# rots. Needs ffmpeg (brew install ffmpeg).

set -euo pipefail

APP="/tmp/lemon-build/Lemon.app"
FRAMES="/tmp/lemon-film"
OUT_DIR="docs/img"
MP4="$OUT_DIR/loop.mp4"
POSTER="$OUT_DIR/loop-poster.png"
FFMPEG="$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)"

[ -d "$APP" ] || { echo "No build at $APP — run 'make build-ui' first."; exit 1; }
[ -x "$FFMPEG" ] || { echo "ffmpeg not found — 'brew install ffmpeg'."; exit 1; }

# 1. Capture frames (app self-terminates after film()).
pkill -f "$APP/Contents/MacOS/Lemon" 2>/dev/null || true
sleep 0.3
rm -rf "$FRAMES"
"$APP/Contents/MacOS/Lemon" --mock --film &
APP_PID=$!
for i in $(seq 1 20); do
  sleep 0.5
  kill -0 $APP_PID 2>/dev/null || break
  [ "$i" -eq 20 ] && { echo "film mode timed out"; kill $APP_PID 2>/dev/null || true; }
done

N=$(ls "$FRAMES"/frame-*.png 2>/dev/null | wc -l | tr -d ' ')
[ "$N" -eq 6 ] || { echo "expected 6 frames, got $N — aborting"; exit 1; }

# 2. Beats are captured at natural popover height (like the real menu-bar
#    popover), so pad them all — TOP-anchored on the page's near-black — to the
#    tallest beat. The popover then appears to grow/shrink between states as it
#    does live, instead of floating in a fixed, mostly-empty frame. Then a ~11s
#    crossfade loop, scaled to 600px wide (even dims for yuv420p) to stay tiny.
cd "$FRAMES"
FFPROBE="${FFMPEG%ffmpeg}ffprobe"
MAXH=$(for f in frame-*.png; do "$FFPROBE" -v error -select_streams v -show_entries stream=height -of csv=p=0 "$f"; done | sort -rn | head -1)
MAXH=$(( (MAXH + 1) / 2 * 2 )) # round up to even
PAD="pad=680:${MAXH}:0:0:color=0x17110A,fps=30,format=yuv420p"
"$FFMPEG" -y -loglevel error \
  -loop 1 -t 2.2 -i frame-0000.png \
  -loop 1 -t 2.2 -i frame-0001.png \
  -loop 1 -t 2.2 -i frame-0002.png \
  -loop 1 -t 2.2 -i frame-0003.png \
  -loop 1 -t 2.2 -i frame-0004.png \
  -loop 1 -t 2.6 -i frame-0005.png \
  -filter_complex "\
    [0]$PAD[v0];[1]$PAD[v1];[2]$PAD[v2];[3]$PAD[v3];[4]$PAD[v4];[5]$PAD[v5];\
    [v0][v1]xfade=transition=fade:duration=0.5:offset=1.7[a];\
    [a][v2]xfade=transition=fade:duration=0.5:offset=3.4[b];\
    [b][v3]xfade=transition=fade:duration=0.5:offset=5.1[c];\
    [c][v4]xfade=transition=fade:duration=0.5:offset=6.8[d];\
    [d][v5]xfade=transition=fade:duration=0.5:offset=8.5,scale=600:-2,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -crf 30 -preset slow -movflags +faststart \
  "$OLDPWD/$MP4"

# 3. Poster = the first beat, padded + scaled to match the video's first frame.
"$FFMPEG" -y -loglevel error -i frame-0000.png \
  -vf "pad=680:${MAXH}:0:0:color=0x17110A,scale=600:-2" "$OLDPWD/$POSTER"

cd "$OLDPWD"
echo "wrote $MP4 ($(du -h "$MP4" | cut -f1)) + $POSTER"
