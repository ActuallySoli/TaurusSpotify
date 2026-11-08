# Web Jam replacement and review — November 6, 2026

This records the earlier replacement pass. The later [live-listening implementation](WEB-JAM-LIVE-2026-11-06.md) supersedes its audio, playlist and browser-test limitations.

## Scope and result

Changes are in `/Users/diyarabbas/Desktop/Taurus-New`. The review covered Browser Player,
Web Jam, the shared Local Jam host/queue/transport, their settings integration and existing
Jam fixtures. It is not a whole-repository security or compatibility audit. No changes were
made to `/Users/diyarabbas/Desktop/taurus`.

The root settings page already contained both Browser Player and Web Jam. Browser Player
has been removed from that page and its implementation excluded from the shipped tweak
in `tweak/Makefile`. Its source files remain available for reference. Web Jam is the single
browser feature on the root page, and the existing Premium, ads & privacy → Jam entry
still opens exactly the same Web Jam page. Both looks use the Shared implementation.

## Findings fixed

- **Hosting outlived Stop.** Web Jam started Local Jam hosting without ending it when
  switched off or when its listener failed. The server now records whether it created
  the host, leaves that host on shutdown, and stops unused nearby transport/discovery.
  An already-running Local Jam host is preserved. Leaving the host through Local Jam
  also stops Web Jam, so it cannot advertise a working request queue after the host ends.
- **Join information did not follow the listener.** The old settings header displayed a
  Wi-Fi URL while off and refreshed its QR code only when the page opened. Links and the
  code now require a ready listener, disappear on Stop/failure, and refresh when the
  interface address changes while the page is visible. Copy, Share and Open actions have
  been added. Failure is reflected in the switch and root status.
- **Artwork accepted arbitrary HTTPS destinations.** Server metadata, browser URL checks
  and the HTTP/HTML content policies now restrict covers to Spotify's public image CDN.
  Spotify image URIs are converted only when they contain a valid hexadecimal image ID.
- **Metadata requests outlived the server.** In-flight title requests are tracked, limited
  to eight, cancelled on Stop, and prevented from updating a later session. Metadata
  payloads over 64 KiB are not parsed. This is a parse limit, not a streamed download cap.
- **Late work could act after a connection ended.** Disconnected requests are marked
  rejected before main-thread queue work. Listener callbacks retain their originating
  generation; old callbacks and queued commands cannot act on a replacement session.
  Queue insertion also requires an active host at the hub boundary.
- **Parsing and browser feedback gaps.** HTTP versions and Content-Length digits are now
  validated strictly. Localized `/intl-xx/track/` Spotify URLs are accepted. The browser
  refreshes when returning to a visible tab, clears stale artwork on connection loss,
  retains typed input after failed requests and shows disabled-button feedback. Input
  length, mobile input sizing, footer contrast and keyboard focus were also improved.
- **Incorrect privacy copy.** The old footer said nothing left the local network, despite
  Spotify oEmbed and artwork requests. The page now explains these requests and that
  anyone on the same Wi-Fi with the address can read the queue and add songs.

## Verification

Passed on this Mac:

- `bash harness/jam/build.sh`: production queue/protocol and track/artwork validation,
  under AddressSanitizer and UndefinedBehaviorSanitizer. Includes queue bounds,
  duplicates, host-only insertion, confirmation before removing a played request and
  advancing only at the current track's end.
- `bash harness/jam/http-build.sh`: production HTTP parser and server lifecycle with a
  stubbed host/listener, under both sanitizers. Includes duplicate/invalid lengths,
  invalid versions, foreign Host/Origin, ownership cleanup, retained Local Jam hosting,
  listener failure, late callbacks and stale/disconnected queue requests.
- `node harness/jam/browser-test.cjs`: the production page script in a simulated DOM;
  covers polling, visibility, allowed/rejected artwork, literal untrusted text, duplicate
  submits, edits during an in-flight request, HTTP errors, offline state and timeouts.
- Layer checks and `git diff --check`.
- `env -u MAKELEVEL THEOS=/Users/diyarabbas/theos gmake -C tweak package`: full arm64 tweak
  package built at `tweak/packages/com.spotipw_0.60.5_iphoneos-arm.deb`. The build's only
  warning was the toolchain's obsolete `-multiply_defined` linker option. No version bump.

The tests do not constitute an on-device or real-browser visual verification. iOS Local
Network permission, QR scanning, Share/Open presentation, Wi-Fi changes and actual Spotify
playback need the device checks below. Other existing edits in the working tree were retained.

## Deliberate limitations and future options

Web Jam is an open local party queue on HTTP port 8787, with no password or revocable
per-session token. Stopping closes the listener, but reopening it at the same address makes
old bookmarks usable again. A guest access code would be a separate feature if private
sessions are wanted. This behavior is now explicit in settings.

The browser submits requests and displays the host's current track/queue; it does not stream
music audio, mirror lyrics/motion, or expose Browser Player's pause/skip controls. Title
lookups may retain “Requested song” if offline, unsuccessful or all lookup slots are busy.
Spotify oEmbed does not reliably supply a track artist. Queue insertion does not prove that
Spotify can play a syntactically valid track ID on the host account.

## Device verification

1. From `/Users/diyarabbas/Desktop/Taurus-New`, run `make install` and restart Spotify.
   Check Native on iOS 16.1+ or Redesigned on iOS 26+. Open Mod Settings: Web Jam should
   appear once on the root page and Browser Player should be absent.
2. Open Web Jam, enable it, allow Local Network access, and keep Spotify open on Wi-Fi.
   The address, QR code and Copy/Share/Open actions should appear when ready. The entry
   under Premium, ads & privacy → Jam should show the same session.
3. From another device on the same Wi-Fi, scan the QR code and add a playable Spotify
   track link. Confirm it enters the queue, a duplicate is refused, and it plays on the
   host as the current song ends. The browser itself should play no audio.
4. Turn Web Jam off: the QR code/actions should disappear and new browser requests should
   fail. Hosting created by Web Jam should end. Repeat with a Local Jam host started first;
   that existing host should remain running after Web Jam is turned off.
