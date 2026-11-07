#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../tweak/Sources" && pwd)
THEOS=${THEOS:-$HOME/theos}
mkdir -p "$HERE/build/AutoMixHooks.app"
"$THEOS/bin/logos.pl" -c generator=internal "${AUTOMIX_HOOK_SOURCE:-$SRC/Shared/AutoMix/AutoMix.x}" > "$HERE/build/AutoMixHooks.m"
python3 - "$HERE/build/AutoMixHooks.m" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s, count = re.subn(r'static __attribute__\(\(constructor\)\) void _logosLocalCtor_\w+\([^)]*\)',
                  'static void SGTestInstallHooks(void)', p.read_text())
assert count == 1
p.write_text(s)
PY
cat > "$HERE/build/AutoMixHooks.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.taurus.automixhooks</string>
<key>CFBundleExecutable</key><string>AutoMixHooks</string>
<key>CFBundleShortVersionString</key><string>9.1.94</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun clang -target arm64-apple-ios26.0-simulator -fobjc-arc -g -isysroot "$SDK" \
    -I"$SRC" -I"$HERE/build" -I"$SRC/Shared/AutoMix" \
    "$HERE/hooks-main.m" "$SRC/Core/SGPrefs.m" "$SRC/Shared/AutoMix/AutoMixModel.m" \
    "$SRC/Shared/AutoMix/AutoMixRuntime.m" "$SRC/Shared/AdBlock/Protobuf.m" \
    -framework Foundation -framework UIKit -o "$HERE/build/AutoMixHooks.app/AutoMixHooks"
xcrun simctl spawn booted "$HERE/build/AutoMixHooks.app/AutoMixHooks"
