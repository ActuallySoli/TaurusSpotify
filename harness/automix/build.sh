#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../tweak/Sources" && pwd)
mkdir -p "$HERE/build"
xcrun clang -fobjc-arc -g -O1 -Wall -Werror -fsanitize=address,undefined \
    -I"$HERE/include" -I"$SRC" "$HERE/main.m" "$SRC/Core/SGPrefs.m" \
    "$SRC/Shared/AutoMix/AutoMixModel.m" "$SRC/Shared/AutoMix/AutoMixRuntime.m" \
    "$SRC/Shared/AdBlock/Protobuf.m" -framework Foundation -o "$HERE/build/automix"
"$HERE/build/automix"
