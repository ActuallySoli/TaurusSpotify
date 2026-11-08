#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p harness/lyrics-clip/build
xcrun clang -fobjc-arc -g -O1 -Wall -Werror -Wno-deprecated-declarations \
  -fsanitize=address,undefined harness/lyrics-clip/main.m \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo \
  -framework Accelerate -framework CoreImage -framework CoreText -o harness/lyrics-clip/build/test
harness/lyrics-clip/build/test
