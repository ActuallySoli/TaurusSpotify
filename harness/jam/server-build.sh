#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p harness/jam/build
python3 scripts/generate-webjam.py --check
xcrun clang -fobjc-arc -g -O1 -Wall -Werror -Wno-unused-parameter -fsanitize=address,undefined \
  -Iharness/jam/include -Itweak/Sources harness/jam/server-main.m \
  tweak/Sources/Core/SGPrefs.m tweak/Sources/Shared/Jam/WebJamRules.m \
  tweak/Sources/Shared/Jam/LocalJam.m tweak/Sources/Shared/Jam/WebJamAudio.m \
  tweak/Sources/Shared/Audio/SGAudioRingBuffer.m tweak/Sources/Shared/Jam/WebJamWeb.m \
  -framework Foundation -framework Network -framework AudioToolbox -o harness/jam/build/server
