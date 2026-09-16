#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CARGO_BIN="${CARGO_BIN:-cargo}"
USE_EXISTING_RUST_BINARIES="${USE_EXISTING_RUST_BINARIES:-0}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to an Apple Development identity from security find-identity -v -p codesigning}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo 'Ad hoc signing is unsupported: hardened runtime rejects the embedded framework without a valid team identity.' >&2
  exit 1
fi
if [[ ! -f Backends/WeChat/Cargo.toml ]]; then
  echo 'Initialize the backend first: git submodule update --init --recursive' >&2
  exit 1
fi
if [[ "$USE_EXISTING_RUST_BINARIES" == "1" ]]; then
  for binary in imcp-wechat imcp-wechat-bootstrap; do
    path="Backends/WeChat/target/release/$binary"
    if [[ ! -x "$path" ]] || ! file "$path" | grep -q 'Mach-O 64-bit executable arm64'; then
      echo "Missing existing ARM64 Rust binary: $path" >&2
      exit 1
    fi
  done
else
  "$CARGO_BIN" build --manifest-path Backends/WeChat/Cargo.toml --locked --release -p imcp-wechat --bins
fi
bash Scripts/build-wechat-ffmpeg.sh
if [[ ! -d .sourcePackages/checkouts/swift-sdk ]]; then
  xcodebuild -resolvePackageDependencies -project iMCP.xcodeproj -scheme iMCP \
    -clonedSourcePackagesDirPath .sourcePackages -onlyUsePackageVersionsFromResolvedFile
fi
bash Scripts/patch-swift-sdk.sh
xcodebuild -project iMCP.xcodeproj -scheme iMCP -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData \
  -clonedSourcePackagesDirPath .sourcePackages -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO IMCP_WEATHERKIT_CONDITION='' build
mkdir -p dist
if [[ -e dist/iMCP.app ]]; then
  mv dist/iMCP.app "dist/iMCP.previous.$(date +%s).app"
fi
ditto .derivedData/Build/Products/Release/iMCP.app dist/iMCP.app
cp Backends/WeChat/target/release/imcp-wechat dist/iMCP.app/Contents/MacOS/
cp Backends/WeChat/target/release/imcp-wechat-bootstrap dist/iMCP.app/Contents/MacOS/
cp .ffmpeg/FFmpeg-n8.0.1/ffmpeg dist/iMCP.app/Contents/MacOS/imcp-ffmpeg
cp .ffmpeg/FFmpeg-n8.0.1/ffprobe dist/iMCP.app/Contents/MacOS/imcp-ffprobe
mkdir -p dist/iMCP.app/Contents/Resources/FFmpegNotices
cp .ffmpeg/FFmpeg-n8.0.1/COPYING.LGPLv2.1 .ffmpeg/ffmpeg-n8.0.1.tar.gz Scripts/build-wechat-ffmpeg.sh dist/iMCP.app/Contents/Resources/FFmpegNotices/
mkdir -p dist/iMCP.app/Contents/Resources/WeChatNotices
cp Backends/WeChat/LICENSE Backends/WeChat/UPSTREAM.md dist/iMCP.app/Contents/Resources/WeChatNotices/
# Re-sign bundled Sparkle from the inside out; Xcode's unsigned copy changes
# its original seal. Updater execution remains disabled in this custom build.
sparkle_root=dist/iMCP.app/Contents/Frameworks/Sparkle.framework
for component in \
  "$sparkle_root/Versions/B/Autoupdate" \
  "$sparkle_root/Versions/B/XPCServices/Downloader.xpc" \
  "$sparkle_root/Versions/B/XPCServices/Installer.xpc" \
  "$sparkle_root/Versions/B/Updater.app" \
  "$sparkle_root"; do
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --preserve-metadata=entitlements "$component"
done
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Scripts/wechat-child.entitlements dist/iMCP.app/Contents/MacOS/imcp-wechat
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Scripts/wechat-child.entitlements dist/iMCP.app/Contents/MacOS/imcp-ffmpeg
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Scripts/wechat-child.entitlements dist/iMCP.app/Contents/MacOS/imcp-ffprobe
# Explicit Terminal helper is not sandboxed; it runs only by user action.
codesign --force --sign "$SIGNING_IDENTITY" --options runtime dist/iMCP.app/Contents/MacOS/imcp-wechat-bootstrap
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Scripts/wechat-app.entitlements dist/iMCP.app
codesign --verify --deep --strict dist/iMCP.app
ditto -c -k --keepParent dist/iMCP.app dist/iMCP-WeChat.zip
echo 'Built dist/iMCP.app and dist/iMCP-WeChat.zip (local signature, not notarized).'
