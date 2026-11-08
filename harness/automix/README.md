# AutoMix harness

Run `sh harness/automix/build.sh` on the Mac. It compiles the production policy, configuration patch
and runtime with AddressSanitizer/UBSan, then supplies plain Objective-C fixtures at Spotify's context,
player-state and preference boundaries. It verifies context selection, immutable caller ownership,
preservation of explicit mixing metadata, core flags, millisecond crossfade duration, no repeated
preference writes, transition/fallback selection and restoration including deliberate user edits.
Apply leaves the playback position alone. Preview seeks to the last 15 seconds only when explicitly
requested, with a following track and a finite duration longer than 15 seconds.

The tests do not run Spotify's audio engine, fetch transition plans or establish audible beat matching.
On a supported Spotify build, enable AutoMix in Mod Settings, restart and play a music playlist. Compare
Smart blend on a playlist with a transition plan against an ordinary album with no plan, check the Status
and Transition details rows. Use Apply to current playback, then Preview next transition to hear the
next boundary sooner. Turn AutoMix off and verify Spotify's own playback settings return.

Run `sh harness/automix/hooks-build.sh` with a booted iOS 26+ simulator to exercise the production Logos
preference hooks. It constructs an existing preferences object without calling `initWithScheduler:`,
then checks discovery through normal reads, replacement-object discovery through writes, restoration,
and 1,000 repeated reads without recursion or extra writes. `AUTOMIX_HOOK_SOURCE=/path/to/AutoMix.x`
selects a prior implementation for regression comparison.
