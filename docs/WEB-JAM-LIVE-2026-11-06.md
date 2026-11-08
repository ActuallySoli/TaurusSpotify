# Web Jam live listening — November 6, 2026

All implementation changes are in `/Users/diyarabbas/Desktop/Taurus-New`.

## What changed

- Guests can hear the host's local playback after tapping **Start listening**. Their own
  volume and Stop control affect only their browser. The relay taps the existing shared
  output after audio effects, with a bounded ring and worker-owned WAV encoding. It does
  not fetch song downloads or save streamed audio to disk.
- The guest page now centers on large artwork, track information, host progress and the
  listening control. Up next, Requests and Played tabs separate the queue, request statuses
  and recent tracks. Guest names, active-tab counts, keyboard navigation, error feedback
  and phone/landscape layouts are included. Fonts and UI assets are served by the host.
- Requests accept Spotify track and playlist URLs/URIs, localized share URLs and bare
  track IDs. Names are sanitized and displayed as text. A playlist request starts the
  native playlist context at a song boundary; it does not enumerate/import all its tracks.
  Later requests take over at the next song boundary. Playback confirmation removes a
  request from the queue; unconfirmed starts time out after twelve seconds and show
  Unavailable. Request history is capped at 100 entries and recent songs at 30.
- Pausing, seeking, changing tracks or output formats, and ending the session invalidate
  buffered audio. Browser requests and scheduled nodes recover from interruption without
  unbounded buffering. Existing Local Jam hosts remain independent when Web Jam stops.

## Design

The page uses the app's black background, near-white type, lilac controls and album art as
its visual focus. A sticky player sits beside the room on desktop; mobile stacks artwork,
listening controls, queue and request form. System typography keeps it consistent with the
native app and avoids font downloads. Motion is limited to control feedback and progress.
Snapshots in `harness/jam/build/webjam-{desktop,phone,landscape,small}.png` use synthetic
artwork and malicious-text fixtures to verify that untrusted content stays literal.

## Verification

Passed:

- Native queue/protocol fixtures under AddressSanitizer and UndefinedBehaviorSanitizer:
  track/playlist URL rules, names, duplicates/caps, host ownership, confirmation-driven
  queue removal, playlist history and unavailable-request timeout.
- HTTP parser/lifecycle fixtures: bounded requests, Host/Origin checks, malformed input,
  stopped generations, disconnection and cleanup.
- Production audio fixture under ASan/UBSan **and ThreadSanitizer**: float32 mono/stereo,
  interleaved/planar layouts, 44.1/48 kHz, untouched host buffers, actual WAV contents,
  sequential guest cursors, pause/seek/track/format revocation, unsupported formats,
  concurrent capture pressure, bounded retention and restart.
- Focused shared-pipeline boundary fixture: Web Jam runs after existing effects/haptics,
  preserves host output and ignores failed renders. This reuses the Core Audio mock
  boundary; it does not claim coverage of Sing's spatial DSP or the older standalone
  `harness/audio/test.py`, which has missing logger/reverb linkage in this checkout.
- Chromium and WebKit against the **production HTTP server, page, queue and audio relay**,
  with a synthetic Spotify player/tone source: nonzero audio decoding and scheduling,
  no autoplay before a guest tap, bounded buffering, pause/resume, Stop, volume, song and
  playlist submission, duplicate protection, input retention, untrusted-text rendering,
  request/history transitions, keyboard tabs, network recovery and responsive layouts.
  WebKit's default downloaded bundle timed out at launch; the local `webkit-2370` bundle
  launched and passed the tests. This is desktop WebKit coverage, not a physical Safari
  or iPhone test.
- Layer checks, generated-asset consistency, whitespace checks, full arm64 tweak and IPA
  builds, ZIP CRC validation, and inspection of the packaged tweak for the audio/UI code.
  The pipeline's Spotify Downloads verification passed. FLEX is absent.

The browser integration follows Web Audio's [user-initiated playback guidance](https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API/Best_practices)
and sends complete WAV files to [decodeAudioData](https://developer.mozilla.org/en-US/docs/Web/API/BaseAudioContext/decodeAudioData),
then schedules them with [AudioBufferSourceNode.start](https://developer.mozilla.org/en-US/docs/Web/API/AudioBufferSourceNode/start).

## Artifact

- File: `out/Taurus-0.60.5-Fixes-20261106-230455.ipa`
- Display name: **Taurus**; original bundle ID retained.
- Spotify: **9.1.90**; tweak version: **0.60.5** (unique artifact name, no release version bump).
- Size: **138,034,696 bytes**.
- SHA-256: `830dd8fe651f8eb5c8c01e945125f6943010056a0f5a8bd4e8d4e69c146455f6`.
- Matching `.ipa.sha256` file beside the IPA. Sign it with the usual sideloading profile;
  this build was packaged, not installed on a phone.

## Additional Bug Fixes (November 6, 2026)

1. **Lock Screen Lyrics — Vinyl text cut-off and rotation pause on lyric change**
   - `tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.m` (`lines 177–196`, `lines 286–382`, `lines 731–754`): Added `CTParagraphStyleRef` (`kCTTextAlignmentCenter`) and vertical line margin to `lineSize` (`lines 177–196`), checked `drawn.width > width` in `drawVinylText` (`lines 286–304`), split Vinyl rendering into `newVinylBaseImage` (`lines 306–322`), `newVinylDiscImage` (`lines 324–361`), `drawVinylCached` (`lines 363–374`), and `drawVinyl` (`lines 376–382`), and cached `vinylBase` / `vinylDisc` once before the 60-frame H.264 loop in `SGLyricsClipWriteInAtTime` (`lines 731–754`).
   - `tweak/Sources/Shared/LockScreenLyrics/LyricsArtwork.x` (`lines 151–173`, `lines 338–343`): Widened `drawAhead` pre-warm horizon from `15 s` to `60 s` (`line 156`) and seeded `sg_previewAskedAt` / `sg_askedAt` on first track offer (`lines 338–343`).
2. **Ambient — Sound stops when pausing a Spotify song while UI stays Playing**
   - `tweak/Sources/Shared/Ambient/AmbientEngine.m` (`lines 38–39`, `lines 371–377`, `lines 386–424`, `lines 597–604`): Added `sg_activatingOwnSession` (`lines 38–39`, `lines 371–377`), added `schedulePlaybackReconcile()` (`lines 390–406`, scheduling `0.01 s`, `0.15 s`, `0.45 s`, `1.0 s` coalesced follow-ups) triggered from `SGAmbientDeferSessionDeactivation` (`lines 408–424`) and `-[SGAmbientPlayerWatcher playerStateDidChange:]` (`lines 597–604`) when paused.
3. **Web Jam — Guest song requests not added to Spotify's in-app queue**
   - `tweak/Sources/Shared/Jam/LocalJam.m` (`lines 145–165`, `lines 599–610`, `lines 862–885`, `lines 933–940`, `lines 974–991`): Added `enqueueTrackInSpotify(NSString *uri)` (`lines 145–165`) calling `-[SPTEsperantoPlayer addToQueue:]` with `+[SPTPlayerTrack trackWithURI:]`, called it in `receiveAdd:peer:` (`line 606`), `addEntryFromOwnPlayer` (`line 935`), and `addWebRequestURI:title:artist:by:` (`line 987`), and updated `playerStateChanged` (`lines 862–885`) to confirm and pop matching entries from `_queue` when native queue playback reaches them.
4. **Premium Spotify Jam Invite — Joining a remote Jam invite asks for Premium**
   - `tweak/Sources/Shared/AdBlock/Premium.m` (`lines 40–43`, `lines 162–166`): Added `jam-social-session = EXPANDED`, `jam-queue-commands-feedback = 1`, `social-session = YES`, `social-session-free-tier = NO` (`lines 40–43`) and remote-config rules (`lines 162–166`).
   - `tweak/Sources/Shared/Jam/Jam.h` (`lines 9–10`) & `tweak/Sources/Shared/Jam/Jam.m` (`lines 1–7`, `lines 52–178`, `lines 199–212`): Added `SGJamProductStateValueForKey` (`lines 64–71`), `SGJamForceUserCapabilities` (`lines 81–106`), and `installJamRuntimeHooks` (`lines 108–178`, called at `line 211`) swizzling `SPTCoreProductState` and `_TtC24Jam_JoinGroupSessionImpl22JamDeeplinkHandlerImpl`.
5. **AutoMix — All songs showing `5 s crossfade (no Spotify plan)`**
   - `tweak/Sources/Shared/AutoMix/AutoMixModel.m` (`lines 24–41`, `lines 51–67`, `lines 69–79`): Stripped `"context://"` in `SGAutoMixContextAllowed` (`line 26`), recognized `audio.fade_out_duration` / `audio.fade_overlap` / `media.stop_position` in `SGAutoMixHasTransition` (`lines 51–67`), and set `patched[@"automix.mode"] = @"regular"` in `SGAutoMixContextMetadata` (`line 74`).
   - `tweak/Sources/Shared/AutoMix/AutoMixRuntime.m` (`lines 266–289`, `lines 323–365`): Updated `SGAutoMixMixWindow` (`lines 266–289`), added `contextURI(id context)` (`lines 332–346`), and updated `SGAutoMixCopyContext` (`lines 348–365`).
   - `tweak/Sources/Shared/AutoMix/AutoMix.x` (`lines 13–35`): Hooked `executePlayCommand:options:loggingParams:origin:` (`lines 22–25`) and `preparePlaybackOfContext:options:viewURI:` (`lines 29–31`) on `SPTEsperantoPlayer`.

## Practical limits and phone verification

Web Jam is a local HTTP room without a password. Anyone on the same Wi-Fi with its address
can listen and request tracks. Streamed sound has a short buffering delay rather than
sample-accurate speaker synchronization. Spotify must play locally on the host iPhone:
audio played only on an external Spotify Connect receiver is unavailable to this capture.
Keep Spotify and the guest tab open; mobile browser/OS background suspension is still an
on-device behavior to check. Guests do not need Spotify accounts; host access to a private
playlist or unavailable track is still decided by Spotify. oEmbed may leave fallback titles.

1. Sign/install the IPA and restart Spotify. Use Native on iOS 16.1+ or Redesigned on
   iOS 26+. Open **Mod Settings → Web Jam**, enable it, and allow Local Network access.
2. Play a song on the host iPhone. On a second device on the same Wi-Fi, scan the QR code
   and tap **Start listening**. Confirm audible music, the expected short delay and local
   volume/Stop controls that leave the host playing.
3. Enter a guest name and request a playable song, then a playlist the host can access.
   Check queue order, status/history updates and playback at song boundaries. Pause/seek
   on the host and verify the guest catches up without replaying a long stale buffer.
4. Switch Web Jam off. The guest stream must stop, the QR code must disappear, and hosting
   created by Web Jam must end. A Local Jam started separately should remain running.
