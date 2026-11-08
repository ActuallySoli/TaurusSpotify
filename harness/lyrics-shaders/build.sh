#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
mkdir -p "$HERE/build"
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -I"$REPO/tweak/Sources" \
    "$HERE/gpu.m" -framework Foundation -framework Metal -o "$HERE/build/gpu"
"$HERE/build/gpu"
