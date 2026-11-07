#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p harness/ambient/build
xcrun clang -fobjc-arc -g -O1 -Wall -Werror -Wno-unused-variable -fsanitize=address,undefined \
  -Iharness/ambient/include -Itweak/Sources harness/ambient/main.m \
  -framework Foundation -framework AudioToolbox -o harness/ambient/build/test
harness/ambient/build/test
