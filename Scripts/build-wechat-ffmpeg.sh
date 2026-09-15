#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .ffmpeg
archive=.ffmpeg/ffmpeg-n8.0.1.tar.gz
if [[ ! -f "$archive" ]]; then
  curl -fLsS --max-time 600 https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.0.1 -o "$archive.download"
  mv "$archive.download" "$archive"
fi
expected=679aa13a19415d5ddab91e580084e3ab20c963c8240001e5cbb955a97bdd81b1
actual=$(shasum -a 256 "$archive")
[[ "${actual%% *}" == "$expected" ]] || { echo 'FFmpeg source checksum mismatch' >&2; exit 1; }
if [[ ! -d .ffmpeg/FFmpeg-n8.0.1 ]]; then
  tar -xzf "$archive" -C .ffmpeg
fi
cd .ffmpeg/FFmpeg-n8.0.1
if [[ ! -x ffmpeg || ! -x ffprobe ]]; then
  ./configure --disable-everything --disable-autodetect --disable-network \
    --disable-doc --disable-debug --disable-shared --enable-static \
    --disable-gpl --disable-nonfree --disable-videotoolbox --disable-audiotoolbox \
    --enable-ffmpeg --enable-ffprobe --enable-zlib \
    --enable-protocol=pipe --enable-demuxer=hevc --enable-parser=hevc \
    --enable-decoder=hevc --enable-encoder=png,gif \
    --enable-muxer=image2pipe,gif --enable-filter=buffer,buffersink,format,scale,split,palettegen,paletteuse
  make -j4
fi
