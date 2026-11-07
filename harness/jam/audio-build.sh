#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p harness/jam/build
SANITIZER=address,undefined
if [ "${TSAN:-0}" = 1 ]; then SANITIZER=thread; fi
xcrun clang -fobjc-arc -g -O1 -Wall -Werror -Wno-unused-parameter -fsanitize="$SANITIZER" \
  -Itweak/Sources harness/jam/audio-main.m tweak/Sources/Shared/Audio/SGAudioRingBuffer.m \
  -framework Foundation -framework AudioToolbox -o harness/jam/build/audio
harness/jam/build/audio
