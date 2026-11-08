#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../tweak/Sources" && pwd)
mkdir -p "$HERE/build"
xcrun clang -fobjc-arc -g -O1 -Wall -Werror -fsanitize=address,undefined \
    -I"$HERE/include" -I"$SRC" "$HERE/main.m" "$SRC/Core/SGPrefs.m" \
    "$SRC/Shared/Jam/LocalJam.m" "$SRC/Shared/Jam/WebJamRules.m" -framework Foundation -o "$HERE/build/jam"
"$HERE/build/jam"
