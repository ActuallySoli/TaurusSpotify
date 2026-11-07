#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p harness/jam/build
xcrun clang -fobjc-arc -g -O1 -Wall -Werror -Wno-unused-parameter -fsanitize=address,undefined \
  -Iharness/jam/include -Itweak/Sources harness/jam/http-main.m \
  tweak/Sources/Core/SGPrefs.m tweak/Sources/Shared/Jam/WebJamRules.m \
  -framework Foundation -framework Network -o harness/jam/build/http
harness/jam/build/http
