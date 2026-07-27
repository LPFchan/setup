#!/bin/sh
# Cut the web deliveries from a master and install them next to index.html.
# Hardware encoder throughout (VideoToolbox).
#
#   ./encode.sh [master.mp4] [poster-seconds]
#
# The source may be any resolution — both renditions are scaled explicitly, so
# a 4K round-trip through an editor encodes correctly. Only the first video
# stream is mapped: editor exports carry an audio and a timecode track, and the
# page plays this muted as a background, so both are dropped.
set -e
cd "$(dirname "$0")"
OUT=..
M=${1:-master.mp4}
POSTER_AT=${2:-15.40}

[ -f "$M" ] || { echo "no $M — run: node render.mjs" >&2; exit 1; }

ffmpeg -v error -y -i "$M" -map 0:v:0 -an -sn -dn \
  -vf "scale=1920:1080:flags=lanczos" \
  -c:v h264_videotoolbox -b:v 2800k -maxrate 3600k -bufsize 5600k \
  -profile:v high -pix_fmt yuv420p \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -tag:v avc1 -movflags +faststart -write_tmcd 0 "$OUT/setup-bg-1080p.mp4"

ffmpeg -v error -y -i "$M" -map 0:v:0 -an -sn -dn \
  -vf "scale=1280:720:flags=lanczos" \
  -c:v h264_videotoolbox -b:v 1300k -maxrate 1700k -bufsize 2600k \
  -profile:v high -pix_fmt yuv420p \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -tag:v avc1 -movflags +faststart -write_tmcd 0 "$OUT/setup-bg-720p.mp4"

# poster: the nested-tmux stack, three machine colours at once
ffmpeg -v error -y -ss "$POSTER_AT" -i "$M" -map 0:v:0 -frames:v 1 -q:v 3 \
  -vf "scale=1920:1080:flags=lanczos" "$OUT/setup-bg-poster.jpg"

ls -la "$OUT"/setup-bg-1080p.mp4 "$OUT"/setup-bg-720p.mp4 "$OUT"/setup-bg-poster.jpg
