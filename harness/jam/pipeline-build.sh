#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p harness/jam/build
SANITIZER=address,undefined
if [ "${TSAN:-0}" = 1 ]; then SANITIZER=thread; fi
xcrun clang -fobjc-arc -g -O1 -Wall -Werror -Wno-deprecated-declarations -fsanitize="$SANITIZER" \
  -Itweak/Sources harness/jam/pipeline-main.m tweak/Sources/Shared/Sing/SGSingAudio.m \
  tweak/Sources/Shared/Sing/SGSingStream.m tweak/Sources/Shared/Sing/SGSingTimeline.m \
  tweak/Sources/Shared/Sing/SGSingDSP.m tweak/Sources/Shared/Audio/SGAudioRingBuffer.m \
  -framework Foundation -framework AudioToolbox -o harness/jam/build/pipeline
harness/jam/build/pipeline
