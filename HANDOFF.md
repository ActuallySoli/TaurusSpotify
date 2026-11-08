# Taurus-New Project Handoff Document

**Date:** 2026-11-07

**Repository:** `/Users/diyarabbas/Desktop/Taurus-New`

**Upstream Sources Reference:**
- GitLab Taurus baseline: `https://gitlab.com/taurustweak/taurus`
- Local Taurus reference: `/Users/diyarabbas/Desktop/taurus`
- Spoti.pw tag: `https://github.com/skopevoj/spoti.pw/tree/v1.0.0-beta.2`
- Chroma binary extract: `/Users/diyarabbas/Downloads/chroma-1.1.0-beta.1.ipa`

---

## 1. Executive Summary & Objective

The goal of this project phase was to bring **Taurus-New** from its initial baseline up to full feature parity with both **Chroma 1.0.1** (from `/Users/diyarabbas/Desktop/taurus`) and the latest **Chroma 1.1.0-beta.1** release, while strictly preserving Taurus's core principles:
1. **100% Free & Open-Source (GPL-3.0):** Completely remove any paywalls (`SGPlus*`), subscription tokens, or cloud service dependencies (`chroma.pw`). All premium capabilities (such as full Recaps, offline animations, and procedural sound engines) are unlocked for all users and executed on-device.
2. **Strict Layer Architecture:** Enforce the one-way import rule checked by `scripts/check-layers.sh`:
   `Core <- Settings <- Shared <- Native | Redesigned <- App`
   (with `Native` and `Redesigned` completely isolated from each other).
3. **Dual Look Support:** Safe runtime gating via `SGNativeUI()` and `SGRedesignedUI()` at the top of every `%ctor`.
4. **Downloads Verification:** Full pass of Spotify offline restriction patches (`verify_downloads.py`).

---

## 2. Completed Implementations & Modules

### A. Chroma 1.1.0-beta.1 Features (Newly Authored & Integrated)

#### 1. Procedural Ambient Sounds (`Shared/Ambient/` & `Redesigned/Ambient/`)
- **Files:**
  - `tweak/Sources/Shared/Ambient/Ambient.h`
  - `tweak/Sources/Shared/Ambient/AmbientEngine.m`
  - `tweak/Sources/Shared/Ambient/AmbientSettings.m`
  - `tweak/Sources/Redesigned/Ambient/AmbientPlayer.x`
- **Capabilities:**
  - Real-time sound synthesis using `AVAudioEngine` + `AVAudioSourceNode` with zero network assets.
  - 9 procedural sound layers: `Rain`, `Thunder`, `Fireplace`, `Wind`, `Forest`, `Ocean`, `Cafe`, `Train`, and `Soft noise` (Pink noise filtered).
  - 6 preset scenes: `Rainy night`, `Fireplace`, `Forest`, `Ocean`, `Cafe`, and `Night train`.
  - Smart playback controls:
    - *Lower during loud music* (`spotifyglass.ambient.duck`) via `AVAudioMixerNode` ducking.
    - *Pause for podcasts* (`spotifyglass.ambient.podcastPause`) triggered by episode URI detection.
    - *Sleep timer fade* (`spotifyglass.ambient.timerFade`).
  - Redesigned player integration: Interactive Liquid Glass ambient chip (`SGRAmbientChip`) placed in the redesigned player header with tap-to-sheet and long-press-to-toggle shortcuts.

#### 2. Unlocked Listening Recaps / Replay (`Shared/ListeningStats/`)
- **Files:**
  - `tweak/Sources/Shared/ListeningStats/Recap.h`
  - `tweak/Sources/Shared/ListeningStats/Recap.m`
  - `tweak/Sources/Shared/ListeningStats/ListeningStatsPage.m`
- **Capabilities:**
  - Full-screen 6-slide interactive stories modeled after Spotify Wrapped / Apple Music Replay, completely unlocked without "Plus" checks.
  - Time horizons: `Weekly`, `Monthly`, `Yearly`, and `All-Time`.
  - Story progression: Segmented animated timer bars, top song breakdown, top 5 songs list, top 5 artists list, morning/afternoon/night listening habits chart, and a shareable summary poster export.
  - Wired into `ListeningStatsPage.m` via *Play as recap*, *All recaps*, and *Announce recaps* toggle.

#### 3. Track-Specific Speed & Pitch (`Shared/Player/`)
- **Files:**
  - `tweak/Sources/Shared/Player/SpeedPitch.h`
  - `tweak/Sources/Shared/Player/SpeedPitch.x`
  - `tweak/Sources/Shared/Player/SpeedPitchMenu.x`
- **Capabilities:**
  - Added **Keep for This Song** (`spotifyglass.speedPitch.songs`).
  - Caches speed (0.5x–2.0x), pitch (-12 to +12 semitones), and Reverbroom settings keyed by track URI.
  - Automatically restores per-song settings as tracks change in `SGPlayerState`.

#### 4. Audio Effects Presets per Output (`Shared/AudioEffects/`)
- **Files:**
  - `tweak/Sources/Shared/AudioEffects/AudioEffectsPresets.h`
  - `tweak/Sources/Shared/AudioEffects/AutoEq.m`
  - `tweak/Sources/Shared/AudioEffects/AudioEffectsPresetsPage.m`
- **Capabilities:**
  - Added **Preset per output** (`spotifyglass.dsp.outputs`).
  - Monitors `AVAudioSessionRouteChangeNotification` and applies designated EQ/DSP presets according to current audio output route (Headphones, Built-in Speaker, Bluetooth, CarPlay).

#### 5. Your Files Page & Metadata Enrichment (`Shared/LocalFiles/`)
- **Files:**
  - `tweak/Sources/Shared/LocalFiles/LocalFiles.h`
  - `tweak/Sources/Shared/LocalFiles/LocalFilesPage.m`
- **Capabilities:**
  - **Your files** settings hub (`SGYourFilesPage`) and local browser (`SGYourFilesBrowserPage`).
  - Import audio files directly into Spotify's sandboxed `Documents` folder via `UIDocumentPickerViewController`.
  - **Suggest tags** (`spotifyglass.localfiles.suggest`) using online iTunes Search API queries to fetch high-res artwork, correct title, artist, album, and track numbering.
  - Offline animated covers download and cache management.

#### 6. Redesigned Full-Screen Album Covers & Notes Placement (`Redesigned/Album/`)
- **Files:**
  - `tweak/Sources/Redesigned/Album/Album.h`
  - `tweak/Sources/Redesigned/Album/AlbumSettings.m`
  - `tweak/Sources/Redesigned/Album/AlbumHeader.x`
- **Capabilities:**
  - **Full screen cover** (`spotifyglass.redesign.album.fullCover`): Stretches album artwork edge-to-edge behind navigation with bottom gradient blur and parallax scroll.
  - **Album notes** placement (`spotifyglass.redesign.album.notesPlace`): Toggles album descriptions between *Above tracks* and *Below tracks*.

---

### B. Chroma 1.0.1 Modules (Synced from `/Users/diyarabbas/Desktop/taurus`)

1. **Browser Player (`Shared/WebPlayer/`):**
   - Built-in lightweight HTTP & WebSocket server (`WebPlayerServer.m`, `WebPlayerFeed.m`, `WebPlayerMedia.m`, `WebPlayerPage.m`).
   - Serves an interactive now-playing web interface over local Wi-Fi with animated canvas playback and playback controls.
   - Fully wired into `ModSettings.x` under `Browser Player`.
2. **Jam & Web Jam (`Shared/Jam/`):**
   - Jam backend unblocking (`Jam.m`, `JamNetwork.m`, `JamSettings.m`).
   - Local Jam queue broadcasting via Bonjour (`LocalJam.m`, `LocalJam.x`, `LocalJamPage.m`).
   - Web Jam HTTP guest queue (`WebJam.m`, `WebJamRules.m`, `WebJamPage.m` on port 8787).
3. **AutoMix (`Shared/AutoMix/` & `Redesigned/Player/`):**
   - Seamless beat-matched crossfades and transition engine (`AutoMix.x`, `PlayerMixing.x`).
4. **Metal Shaders & Spectrum Visualizer (`Redesigned/Player/Shaders/`):**
   - Metal-based animated shaders for the player and karaoke lyrics backgrounds (`SGRShaders.m`, `SGRShaderCompiler.m`, `SGRShaderLibrary.m`, `SGRSpectrum.m`).
5. **Lock Screen Lyrics Artwork (`Shared/LockScreenLyrics/`):**
   - 7 customizable Lock Screen lyric presentation styles (`Full screen`, `Poster`, `Vinyl`, `Messages`, `Polaroid`, `Stickers`, `Duotone`) via `SGLyricsClip.m` and `LyricsArtwork.x`.
6. **Custom Fonts Catalog (`Shared/Fonts/`):**
   - Google Fonts catalog browser and on-demand font downloader (`FontCatalog.m`, `FontImport.m`).
7. **Navbar Profile Button Placement (`Redesigned/Navbar/` & `Redesigned/Library/`):**
   - Profile avatar icon routing and placement in the navigation bar and library header (`NavbarProfile.m`, `LibraryHeader.x`).
8. **Downloads Patch & Pipeline Tools (`extension/Downloads/`, `scripts/pipeline.sh`):**
   - Updated offline restrictions and native key trace patcher tools.

---

## 3. Architecture & Code Compliance Status

- **Layer Verification (`scripts/check-layers.sh`):**
  - Result: **Passed (0 errors)**.
  - Clean separation: `Core <- Settings <- Shared <- Native | Redesigned <- App`.
- **Runtime Guardrails:**
  - Native hooks protected with: `if (!SGNativeUI()) return;`
  - Redesign hooks protected with: `if (!SGRedesignedUI()) return;`
- **Compiler Compatibility:**
  - Modern iOS 26 Liquid Glass compatibility: `SGGlassFor()` and `SGShapeGlass()` used instead of deprecated or undefined APIs.
  - Resolved deprecated `contentEdgeInsets` and implicit C99 declarations.

---

## 4. Current Build & Deliverables

Latest build recorded here: November 7, 2026, Taurus 0.60.5 on Spotify 9.1.90.
The lyrics-shaders IPA was built from the current working tree, including the existing changes
from other tasks. Its filename is unique; the mod version was not bumped. Device signing and
installation were not performed in this task.

| Artifact | Location | Status |
|---|---|---|
| **Compiled Tweak DEB** | `tweak/packages/com.spotipw_0.60.5_iphoneos-arm.deb` | Built & signed |
| **Downloads Verification** | Injected `SpotifyAudioProbe.dylib` | 100% Verified passed |
| **Latest Release IPA — Lyrics Shaders** | `out/Taurus-0.60.5-LyricsShaders-20261107-205155-AF5B87A8.ipa` (138,043,022 bytes, SHA-256: `cb56a6d53c8f0ec4a3638ceb8710b6d653023fd22b081a9a8a1c169319860f2b`) | Archive integrity and embedded shader renderer verified; no FLEX; requires signing for device installation |
| **Release Build Log** | `out/lyrics-shaders-release-build.log` | Build completed; finished-IPA Downloads verification passed |
| **Previous Release IPA — November 6** | `out/Taurus-0.60.5-Fixes-20261106-230455.ipa` (138,034,696 bytes, SHA-256: `830dd8fe651f8eb5c8c01e945125f6943010056a0f5a8bd4e8d4e69c146455f6`) | Historical build evidence |

---

## 5. Bug Fixes & Root-Cause Resolutions (November 6, 2026)

1. **Lock Screen Lyrics — Vinyl (`tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.m`, `tweak/Sources/Shared/LockScreenLyrics/LyricsArtwork.x`)**
   - **Files & Line Ranges Changed:**
     - [SGLyricsClip.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.m#L177-L196) (`lines 177–196`): Updated `lineSize` to include the centered `CTParagraphStyleRef` (`kCTTextAlignmentCenter`) and a `+2` vertical height margin.
     - [SGLyricsClip.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.m#L286-L382) (`lines 286–382`): Updated `drawVinylText` (`lines 286–304`) to shrink `fontSize` when `drawn.height > maxHeight || drawn.width > width`, and split Vinyl rendering into `newVinylBaseImage` (`lines 306–322`), `newVinylDiscImage` (`lines 324–361`), `drawVinylCached` (`lines 363–374`), and `drawVinyl` (`lines 376–382`).
     - [SGLyricsClip.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.m#L731-L754) (`lines 731–754`): Pre-rendered `vinylBase` and `vinylDisc` once before the 60-frame encoding loop in `SGLyricsClipWriteInAtTime` and drew each frame with `drawVinylCached`.
     - [LyricsArtwork.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/LyricsArtwork.x#L151-L173) (`lines 151–173`): Widened the `drawAhead` pre-warm window from `15` seconds to `60` seconds (`line 156`).
     - [LyricsArtwork.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/LyricsArtwork.x#L338-L343) (`lines 338–343`): Seeded `sg_previewAskedAt` and `sg_askedAt` on initial track offer in `tick` so upcoming lyric clips are pre-encoded before line transitions.
   - **Root causes:** `lineSize` omitted the centered `CTParagraphStyleRef` used by `CTFramesetterCreateFrame`, causing borderline wraps to clip the bottom line; `SGLyricsClipWriteInAtTime` re-rendered the full 600×600 Gaussian-blurred text and cover 60 times on a background thread when a line wasn't pre-warmed (`drawAhead` was only 15s and unseeded on initial track offer), stalling the artwork swap and making the vinyl appear to pause.
   - **Verification:** `bash harness/lyrics-clip/build.sh` (all 21 checks passed).

2. **Ambient — Stops Playing When Song Pauses (`tweak/Sources/Shared/Ambient/AmbientEngine.m`)**
   - **Files & Line Ranges Changed:**
     - [AmbientEngine.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Ambient/AmbientEngine.m#L38-L39) (`lines 38–39`): Added `static _Atomic bool sg_activatingOwnSession = false;`.
     - [AmbientEngine.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Ambient/AmbientEngine.m#L371-L377) (`lines 371–377`): Guarded `[session setActive:YES error:&error]` in `ensureEngineStarted` with `sg_activatingOwnSession` so Ambient's own activation does not clear deferred deactivation options.
     - [AmbientEngine.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Ambient/AmbientEngine.m#L386-L424) (`lines 386–424`): Added `schedulePlaybackReconcile` (`lines 390–406`, scheduling coalesced `0.01s`, `0.15s`, `0.45s`, `1.0s` follow-ups) and updated `SGAmbientDeferSessionDeactivation` (`lines 408–424`) to preserve `kSessionDeferred` when `sg_activatingOwnSession` is true and call `schedulePlaybackReconcile()`.
     - [AmbientEngine.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Ambient/AmbientEngine.m#L597-L604) (`lines 597–604`): Called `schedulePlaybackReconcile()` in `-[SGAmbientPlayerWatcher playerStateDidChange:]` when `!state || state.isPaused`.
   - **Root causes:** Pausing a Spotify song triggers a delayed CoreAudio/AudioUnit teardown 50–300ms after `playerStateDidChange:` and `setActive:NO`, stopping `AVAudioEngine` without firing `AVAudioEngineConfigurationChangeNotification`. Additionally, `ensureEngineStarted()` calling `[session setActive:YES error:]` re-entered `SGAmbientDeferSessionDeactivation(YES, 0)` and cleared `kSessionDeferred` options.
   - **Verification:** `bash harness/ambient/build.sh` (all 23 checks passed).

3. **Web Jam — Song Requests Not Queued in App (`tweak/Sources/Shared/Jam/LocalJam.m`)**
   - **Files & Line Ranges Changed:**
     - [LocalJam.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Jam/LocalJam.m#L145-L165) (`lines 145–165`): Added `enqueueTrackInSpotify(NSString *uri)` using `+[SPTPlayerTrack trackWithURI:]` and `-[SPTEsperantoPlayer addToQueue:]`.
     - [LocalJam.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Jam/LocalJam.m#L599-L610) (`lines 599–610`): Called `enqueueTrackInSpotify(entry.uri)` in `-[SGLocalJamHub receiveAdd:peer:]` (`line 606`).
     - [LocalJam.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Jam/LocalJam.m#L862-L885) (`lines 862–885`): Updated `-[SGLocalJamHub playerStateChanged]` to match and remove any track entry in `self.queue` when Spotify's native queue reaches that track.
     - [LocalJam.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Jam/LocalJam.m#L933-L940) (`lines 933–940`): Called `enqueueTrackInSpotify(entry.uri)` in `-[SGLocalJamHub addEntryFromOwnPlayer]` (`line 935`).
     - [LocalJam.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Jam/LocalJam.m#L974-L991) (`lines 974–991`): Called `enqueueTrackInSpotify(uri)` in `-[SGLocalJamHub addWebRequestURI:title:artist:by:]` (`line 987`).
   - **Root cause:** `addWebRequestURI:title:artist:by:` only appended to `_queue` and waited until `< 0.75s` remaining to call `playURI:`, so requested tracks never appeared in Spotify's in-app Queue UI.
   - **Verification:** `bash harness/jam/build.sh` (`PASS: local jam protocol end to end`).

4. **Premium Spotify Jam Invite — Joining Asks for Premium (`tweak/Sources/Shared/AdBlock/Premium.m`, `tweak/Sources/Shared/Jam/Jam.h`, `tweak/Sources/Shared/Jam/Jam.m`)**
   - **Files & Line Ranges Changed:**
     - [Premium.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AdBlock/Premium.m#L40-L43) (`lines 40–43`): Added `@"jam-social-session": @"EXPANDED"`, `@"jam-queue-commands-feedback": @"1"`, `@"social-session": @YES`, and `@"social-session-free-tier": @NO` in `forcedAttributes()`.
     - [Premium.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AdBlock/Premium.m#L162-L166) (`lines 162–166`): Added remote-config rules forcing `ads_disclaimer_sheet_enabled = NO`, `free_user_enabled_to_host_in_person_jam = YES`, `is_nearby_jam_invite_deeplink_enabled = YES`, `join_sheet_from_join_options_enabled = YES`, and `nearby_session_invitation_enabled = YES`.
     - [Jam.h](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Jam/Jam.h#L9-L10) (`lines 9–10`): Declared `SGJamProductStateValueForKey(NSString *key)` and `SGJamForceUserCapabilities(id target)`.
     - [Jam.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Jam/Jam.m#L1-L7) (`lines 1–7`): Imported `Core/SGPrefs.h`, `Core/SGLog.h`, `Core/SGFlagForce.h`, and `<objc/runtime.h>`.
     - [Jam.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Jam/Jam.m#L52-L178) (`lines 52–178`): Added Jam join/deeplink flags in `unlockValue` (`lines 52–62`), implemented `SGJamProductStateValueForKey` (`lines 64–71`), `setByteIvarIfPresent` (`lines 73–79`), `SGJamForceUserCapabilities` (`lines 81–106`), and `installJamRuntimeHooks` (`lines 108–178`) swizzling `SPTCoreProductState` and `_TtC24Jam_JoinGroupSessionImpl22JamDeeplinkHandlerImpl`.
     - [Jam.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Jam/Jam.m#L199-L212) (`lines 199–212`): Invoked `installJamRuntimeHooks()` in `registerJam` (`line 211`).
   - **Root cause:** `_TtC24Jam_JoinGroupSessionImpl22JamDeeplinkHandlerImpl` and `_TtC17Jam_JoinSheetImpl32JoinSheetPresenterImplementation` read `SPTCoreProductState` key `"jam-social-session"` (which must be `"EXPANDED"` so `canJoinRemoteSession` at `userCapabilities + 4` is `1`). When `"jam-social-session"` was unset, `canJoinRemoteSession` was `0`, routing remote Jam invite links directly to the Premium upsell sheet.
   - **Verification:** `bash harness/jam/invite-build.sh` (all checks passed).

5. **AutoMix — All Songs Showing `5s crossfade (no Spotify plan)` (`tweak/Sources/Shared/AutoMix/AutoMixModel.m`, `tweak/Sources/Shared/AutoMix/AutoMixRuntime.m`, `tweak/Sources/Shared/AutoMix/AutoMix.x`)**
   - **Files & Line Ranges Changed:**
     - [AutoMixModel.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AutoMix/AutoMixModel.m#L24-L41) (`lines 24–41`): Stripped leading `"context://"` prefix in `SGAutoMixContextAllowed` (`line 26`).
     - [AutoMixModel.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AutoMix/AutoMixModel.m#L51-L67) (`lines 51–67`): Extended `SGAutoMixHasTransition` to recognize positive `audio.fade_out_duration`, `audio.fade_overlap`, and `media.stop_position` values in addition to `audio.fade_out_start_time` and `automix.transition_uri`.
     - [AutoMixModel.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AutoMix/AutoMixModel.m#L69-L79) (`lines 69–79`): Changed `patched[@"automix.mode"]` from `@"auto"` to `@"regular"` (`line 74`) in `SGAutoMixContextMetadata`.
     - [AutoMixRuntime.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AutoMix/AutoMixRuntime.m#L266-L289) (`lines 266–289`): Updated `SGAutoMixMixWindow` to compute the transition window from `media.stop_position` or `duration` when `audio.fade_out_duration` / `audio.fade_overlap` is provided without `audio.fade_out_start_time`.
     - [AutoMixRuntime.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AutoMix/AutoMixRuntime.m#L323-L365) (`lines 323–365`): Added `media.stop_position` to `SGAutoMixTransitionDetails` (`line 324`), added `contextURI(id context)` (`lines 332–346`) to resolve the first non-empty URI across `URI`, `uri`, `URL`, `url`, and `pages.firstObject.pageURL`, and updated `SGAutoMixCopyContext` (`lines 348–365`) to use `contextURI` and pass `[patched mutableCopy]`.
     - [AutoMix.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AutoMix/AutoMix.x#L13-L35) (`lines 13–35`): Hooked `-executePlayCommand:options:loggingParams:origin:` (`lines 22–25`) and `-preparePlaybackOfContext:options:viewURI:` (`lines 29–31`) on `SPTEsperantoPlayer`.
   - **Root causes:** `SGAutoMixContextMetadata` set `patched[@"automix.mode"] = @"auto"`, which in Spotify 9.1.90's C++ `core-automix` planner (`0x102867674`) requires a non-empty `automix.auto_preset_id` and bails out without planning on normal playlists, albums, or Liked Songs; `SGAutoMixCopyContext` also missed contexts whose URI lived in `URL`/`url` (`"context://spotify:playlist:..."`) when `ESPContext.uri` was `@""`.
   - **Verification:** `bash harness/automix/build.sh` (all checks passed).

6. **Lock Screen Beautiful Lyrics — Karaoke Word Sweep, Zero-Flash Handoff & Pause Freeze-Frame (`tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.h`, `tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.m`, `tweak/Sources/Shared/LockScreenLyrics/LyricsArtwork.x`, `tweak/Sources/Shared/AnimatedArtwork/AnimatedArtworkSettings.m`, `harness/lyrics-clip/main.m`)**
   - **Files & Line Ranges Changed:**
     - [SGLyricsClip.h](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.h#L53-L79) (`lines 53–79`): Added `SGLyricsClipWord`, `SGLyricsClipKaraokeSpec`, `SGLyricsClipKaraokeFrame(...)`, and `SGLyricsClipWriteKaraoke(...)`.
     - [SGLyricsClip.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.m#L168-L382) (`lines 168–382`): Implemented `KaraokePlan`, `makeKaraokePlan`, `freeKaraokePlan`, `buildAutoWords`, `drawKaraokeActiveLine`, and `drawKaraokeFrameInContext` for Beautiful Lyrics (`SGLyricsClipWords`), rendering a 3-line stack (`previous`, `line`, `next`) with `vImageTentConvolve_ARGB8888` depth-of-field blur on neighbour lines, per-word and per-character S-curve karaoke sweep (`0.36 -> 1.0` alpha), continuous song-time background breathing, and cubic-out vertical scroll-in over the first `0.28s`.
     - [SGLyricsClip.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/SGLyricsClip.m#L887-L1116) (`lines 887–1116`): Implemented `SGLyricsClipKaraokeFrame` (`lines 887–919`) and `SGLyricsClipWriteKaraoke` (`lines 921–1001`) and routed `SGLyricsClipFrameInAtTime`, `SGLyricsClipWriteInAtTime`, and `SGLyricsClipWrite` for `SGLyricsClipWords` through the karaoke renderer.
     - [LyricsArtwork.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/LyricsArtwork.x#L21-L48) (`lines 21–48`): Extended `SGLockLine` with `wordSpans`, `elapsedInLine`, `sungDuration`, and `scrollIn`, and added `sg_resumeTrack`, `sg_resumeIndex`, and `sg_resumeBucket` state.
     - [LyricsArtwork.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/LyricsArtwork.x#L113-L200) (`lines 113–200`): Added `karaokeSpecFor(SGLockLine *line)` (`lines 113–128`), updated `previewFor` and `writeClip` to call `SGLyricsClipKaraokeFrame` / `SGLyricsClipWriteKaraoke`, and updated `drawAhead(artworkID, line, urgent)` (`lines 173–199`) to re-trigger `tick()` on main once an urgent asset completes.
     - [LyricsArtwork.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/LockScreenLyrics/LyricsArtwork.x#L264-L450) (`lines 264–450`): Populated `wordSpans` and `sungDuration` from `SGKaraokeLine.words` in `lineAt` (`lines 264–307`); added pause freeze-frame generation (`-p<bucket>`, `SGLyricsClipStill`, exact `elapsedInLine` and `from = position / 1000.0`) and seamless mid-line resume (`-res<bucket>`) in `tick()` (`lines 374–402`); and gated `SGNowPlayingSetExtras` until both `sg_previews[artworkID]` and `sg_clips[artworkID]` are cached (`lines 418–438`), eliminating the plain-cover flash on line changes.
     - [AnimatedArtworkSettings.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AnimatedArtwork/AnimatedArtworkSettings.m#L32-L38) (`lines 32–38`): Defaulted `SGKeyLockScreenLyricsStyle` to `SGLyricsClipAnimated` and `SGKeyLockScreenLyricsLook` to `SGLyricsClipWords` (`Full screen`).
     - [main.m](file:///Users/diyarabbas/Desktop/Taurus-New/harness/lyrics-clip/main.m#L81-L111) (`lines 81–111`): Added Beautiful Lyrics word-sweep, freeze-frame, and H.264 clip verification checks.
   - **Verification:** `bash harness/lyrics-clip/build.sh` (all 24 checks passed).

7. **Fades on Pause & Resume, and Reverb (`tweak/Sources/Shared/Player/SpeedPitch.h`, `tweak/Sources/Shared/Player/SpeedPitch.x`, `tweak/Sources/Shared/Player/SpeedPitchMenu.x`, `tweak/Sources/Redesigned/Player/PlayerControls.x`, `tweak/Sources/Shared/AudioEffects/AudioEffectsPage.m`, `tweak/Sources/Shared/AudioEffects/AudioEffectsSettings.m`)**
   - **Files & Line Ranges Changed:**
     - [SpeedPitch.h](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Player/SpeedPitch.h#L21-L28) (`lines 21–28`): Added `SGKeyFadeOnPause` (`"spotifyglass.speedPitch.fadeOnPause"`), `SGPlayerFadeOnPause()`, and `SGSetPlayerFadeOnPause(BOOL on)`.
     - [SpeedPitch.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Player/SpeedPitch.x#L15-L27) (`lines 15–27`), [SpeedPitch.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Player/SpeedPitch.x#L144-L195) (`lines 144–195`), [SpeedPitch.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Player/SpeedPitch.x#L243-L253) (`lines 243–253`), and [SpeedPitch.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Player/SpeedPitch.x#L404-L625) (`lines 404–625`): Added sample-accurate cosine S-curve gain envelope in `scaleInPlace` (`SGAudioStageSpeedPitch`, ahead of `SGAudioStageEffects` so `SGDSPReverb` rings out naturally on pause), plus `240 ms` pause fade-out and `260 ms` resume fade-in hooks on `_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView`, `SPTNowPlayingPlaybackControllerImplementation`, and `SPTEsperantoPlayer`.
     - [SpeedPitchMenu.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Player/SpeedPitchMenu.x#L76-L80) (`lines 76–80`) and [SpeedPitchMenu.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/Player/SpeedPitchMenu.x#L219-L435) (`lines 219–435`): Added `Fade on pause` switch row to the `Speed, pitch and reverb` sheet.
     - [PlayerControls.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Redesigned/Player/PlayerControls.x#L277-L287) (`lines 277–287`): Called `playTapped()` before `%orig` in `-[_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView uiButtonTapped]` so the Play/Pause button icon flips immediately when tapped while the `240 ms` pause fade runs.
     - [AudioEffectsPage.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AudioEffects/AudioEffectsPage.m#L137-L141) (`lines 137–141`) and [AudioEffectsSettings.m](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Shared/AudioEffects/AudioEffectsSettings.m#L77-L84) (`lines 77–84`): Added the `Amount` (`%`) slider row to the `Reverb` card on the `Audio effects` page and defaulted `SGKeyDSPReverbAmount` to `35%` when toggled on from `0%`.

8. **Explicit `"E"` Badge Visibility (`tweak/Sources/Redesigned/Kit/SGRPlainCheck.x`, `tweak/Sources/Redesigned/Playlist/PlaylistRows.x`, `tweak/Sources/Redesigned/Album/AlbumRows.x`)**
   - **Files & Line Ranges Changed:**
     - [SGRPlainCheck.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Redesigned/Kit/SGRPlainCheck.x#L73-L162) (`lines 73–162`): Added `explicitBadgeImage(BOOL nineteenPlus)` (`lines 81–125`) rendering a high-contrast `13x13pt` (`@3x`) Apple Music style badge (`78%` white rounded pill with a heavy dark `0.05` `"E"` or `"19"` glyph), cleared `view.backgroundColor` and hid underlying Spotify subviews on every `layoutSubviews` pass (`lines 127–162`), and kept dark `0.06` text on stock Spotify `ExplicitBadge` labels when `SGRKeyPrettierIcons` is disabled.
     - [PlaylistRows.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Redesigned/Playlist/PlaylistRows.x#L59-L72) (`lines 59–72`) and [AlbumRows.x](file:///Users/diyarabbas/Desktop/Taurus-New/tweak/Sources/Redesigned/Album/AlbumRows.x#L128-L140) (`lines 128–140`): Skipped `UILabel`s inside `ExplicitIcon` / `ExplicitBadge` ancestors when recolouring row `Subtitle` labels to `SGRSecondary()`.


---

## 6. Chroma-Style Lyrics Word Shaders (November 7, 2026)

### Scope and implementation

The five existing gradient word effects were replaced with procedural Metal fills: **Neon**
(color ribbons), **Inferno** (flowing flames), **Hologram** (prism scanlines), **Chrome**
(liquid reflections), and **Blueprint** (drafting grid). These are independently authored
recreations of the styles named in [Chroma's public lyrics preview](https://chroma.pw/),
not extracted Chroma shader code or a verified pixel-for-pixel port. No Workshop content or
Chroma account is required. Classic retains the original text.

This change is confined to the **Redesigned UI on iOS 26+**, using the existing karaoke
renderer integration. It changes the fills inside sung words, not the player backgrounds
or lock-screen lyric clips. No Spotify hooks were added.

- `tweak/Sources/Redesigned/Lyrics/SGRLyricsShaderSource.h`: the five Metal fills and glyph-mask shader.
- `tweak/Sources/Redesigned/Lyrics/SGRLyricsShaderEffect.m`: replaces animated gradient layers
  with one transparent Metal surface per active word; glyph textures follow the existing
  letter positions and inherit the word's karaoke timing mask.
- `tweak/Sources/Redesigned/Lyrics/LyricsLookSettings.m`: renames Word effect to **Lyrics shader**
  and updates the descriptions. Open **Mod Settings → Lyrics → Adjust → Lyrics shader**.
  Existing intensity, speed, saved selections and JSON effect-profile formats remain compatible;
  these controls apply immediately.
- `docs/tweaks.md` and `harness/lyrics-shaders/README.md`: implementation and verification notes.

Pipeline compilation and GPU submission run off the UI thread. The existing lyrics display
link drives rendering; there is no additional display link. Each effect permits one GPU frame
in flight, and queued submissions can be disabled when stopped or invalidated. Shared budgets
limit active glyph masks to 48 / 512K pixels and surfaces to 12 / 2M pixels. Paused/offscreen
lyrics, Reduce Motion, exhausted budgets and Metal failures retain static text. Real-device
performance and battery impact have not been measured.

### Verification completed November 7

- `bash harness/lyrics-shaders/build.sh`: all five shaders compiled and rendered on the Mac GPU;
  checks passed for distinct styles, time-varying output, repeatable output after seeking,
  premultiplied alpha, transparent mask regions and intensity scaling.
- `bash harness/lyrics-shaders/preview.sh`: production renderer exercised in an isolated UIKit
  harness on the iOS 27.0 simulator. Passed invalid-input and mask-budget checks, repeated
  invalidation, five simultaneous styles, joined Arabic text, pause/resume and cleanup with
  GPU frames in flight. The harness logged PASS and wrote `Documents/result.txt` in its data
  container. Its five styles and Arabic text were visually inspected; the harness was then
  terminated. Preview: `harness/lyrics-shaders/build/preview.png` (generated, gitignored).
- iPhoneOS Objective-C syntax check, `git diff --check`, and
  `bash scripts/check-layers.sh tweak/Sources`: passed.
- Release built using `scripts/pipeline.sh` with the local Spotify 9.1.90 IPA, `--no-flex`, and
  the unique output path in section 4. Tweak, Live Activity, Safari extension and App Group shim
  built successfully. Existing unrelated deprecation/linker warnings remain in the build log.
- Finished IPA: ZIP integrity passed; the injected tweak contains `lyricsVertex`,
  `lyricsFragment`, `SGRLyricsShaderSubmission` and the Lyrics shader setting; FLEX is absent.
  Downloads verification passed for offline restrictions, key mode and native observation.
  The artifact's size and SHA-256 were checked again when this handoff was updated.

### Remaining device verification

Sign and install the **LyricsShaders IPA listed in section 4** on an iPhone running **iOS 26+**.
Enable **Redesigned UI** and restart Spotify if changing looks. Open **Mod Settings → Lyrics →
Adjust → Lyrics shader**, select each style, then play a song with timed lyrics in the redesigned
player. Confirm animated fills stay inside sung words and follow the letter motion in portrait
and landscape; check pause/resume, seeking, track changes, leaving/reopening lyrics and Reduce
Motion. Select Classic to confirm the original text returns. The simulator checks do not establish
full Spotify integration, iOS 26 device behavior, or hardware performance/battery results.
