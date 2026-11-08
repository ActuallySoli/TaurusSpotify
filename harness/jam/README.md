# Jam checks

Run from the repository root:

```sh
bash harness/jam/build.sh
bash harness/jam/http-build.sh
bash harness/jam/audio-build.sh
TSAN=1 bash harness/jam/audio-build.sh
bash harness/jam/pipeline-build.sh
```

The native checks require macOS and Xcode command-line tools. They exercise production
request parsing/queue/playback confirmation, lifecycle, PCM capture, WAV envelopes, stale
stream revocation, bounded memory and the output-stage ordering. ASan/UBSan is the default;
TSAN selects ThreadSanitizer for the concurrent capture checks. The pipeline check reuses
the existing Core Audio mock boundary for a focused after-effects ordering test. It does
not run the legacy Sing assertions or test spatial reverb; logging/reverb are stubbed.

For the real browser/server integration:

```sh
python3 -m venv /tmp/webjam-browser
/tmp/webjam-browser/bin/pip install playwright
/tmp/webjam-browser/bin/python -m playwright install chromium webkit
WEBJAM_PYTHON=/tmp/webjam-browser/bin/python node harness/jam/browser-test.cjs
```

The entry point builds the production Network.framework HTTP server, production Local Jam
hub, page and audio relay. Only Spotify's player, audio input and nearby transport are
replaced with fixture implementations. It generates a test tone; no Spotify login or real
music is used. oEmbed results for fixture IDs are seeded locally. The guest browser decodes
and schedules the actual audio packets, and drives real HTTP song/playlist requests.

The HTTP fixture and browser server need an IPv4 Wi-Fi address on `en0`. The browser fixture
opens port 8787 on Wi-Fi during the test, stops on completion and removes its stored switch.
Do not run it alongside another server on that port. `WEBJAM_BROWSERS=chromium` or `webkit`
selects an engine; `WEBJAM_WEBKIT_EXECUTABLE` can select an installed `pw_run.sh` when the
default browser bundle cannot launch. The combined passing run used Chromium 148 and
WebKit 26.4, with the local `webkit-2370` bundle selected explicitly.

Screenshots, native binaries and logs go under ignored `harness/jam/build/`. Layout checks
cover 320, 390, 844 and 1440 px with reduced motion. Browser checks cover opt-in audio,
nonzero decoded PCM, bounded scheduling, pause/resume, Stop, per-guest volume, duplicate
submissions, retained input, literal untrusted text, request history, playlist confirmation,
keyboard tabs and network recovery. These tests do not establish physical iPhone playback,
iOS background audio or Spotify Connect receiver capture.

See `docs/WEB-JAM-LIVE-2026-11-06.md` for the compiled IPA and device verification steps.
