#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
APP="$HERE/build/LyricsShaders.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -target arm64-apple-ios26.0-simulator -fobjc-arc -Wall ${SHADER_TEST_FLAGS:--DSGR_LYRICS_SHADER_TESTING=1} \
    -isysroot "$SDK" -I"$REPO/tweak/Sources" "$HERE/preview.m" \
    "${SHADER_SOURCE:-$REPO/tweak/Sources/Redesigned/Lyrics/SGRLyricsShaderEffect.m}" \
    -framework Foundation -framework CoreGraphics -framework UIKit -framework QuartzCore -framework Metal -framework MetalKit -o "$APP/LyricsShaders"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LyricsShaders</string>
<key>CFBundleIdentifier</key><string>com.taurus.lyricsshaders.harness</string>
<key>CFBundleName</key><string>Lyrics Shaders</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>UIUserInterfaceStyle</key><string>Dark</string>
<key>CADisableMinimumFrameDurationOnPhone</key><true/>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
codesign -f -s - "$APP"
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.taurus.lyricsshaders.harness
