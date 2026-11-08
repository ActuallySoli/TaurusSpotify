# Ambient lifecycle regression harness

Run from the repository root:

```sh
bash harness/ambient/build.sh
```

Compiles the production Ambient engine under AddressSanitizer and UndefinedBehaviorSanitizer.
The AVAudioEngine, AVAudioSession and player boundaries are scripted; synthesized audio is rendered
by the production source-node callback and checked for nonzero samples. Mock classes use unique
Objective-C runtime names to avoid colliding with macOS audio frameworks.

Coverage includes standalone playback, music play/pause, deferred session deactivation and option
preservation, manual Stop, interruption/resume rules, Stop during interruption, podcast pause,
configuration changes, media-service resets, activation/start failures, preserving a recording-capable
session, and explicit sleep stop. Status and enabled/playback state are checked separately.

The fixture uses the same session policy as the two Logos hooks. It does not execute iOS's actual
AVAudioSession, prove which Spotify deactivation call occurs on a physical phone, or verify Bluetooth,
AirPlay, phone-call audio, or background playback. The full tweak build checks the hook signatures.

On a phone, enable Ambient, play and pause a song, and confirm Ambient continues. Stop Ambient in
settings and confirm it stops without pausing a playing song. Repeat through a phone interruption,
headphone route change, and the optional podcast/sleep controls.
