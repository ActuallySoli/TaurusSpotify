#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p harness/jam/build
xcrun clang -fobjc-arc -Wall -Werror -fsanitize=address,undefined -Iharness/jam/include -Itweak/Sources \
  harness/jam/invite-main.m tweak/Sources/Shared/Privacy/CleanLinks.m tweak/Sources/Shared/Jam/JamFailure.m \
  tweak/Sources/Shared/Jam/Jam.m tweak/Sources/Core/SGPrefs.m \
  -framework Foundation -o harness/jam/build/invite
harness/jam/build/invite
