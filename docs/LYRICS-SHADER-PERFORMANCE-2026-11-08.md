# Lyrics shader performance investigation

Reported target: iPhone 16e, iOS 27. Reported symptoms: stuttering/delay, flickering or doubled letters, heat/battery use, and crashes/freezes. Investigation completed November 8, 2026. No iPhone 16e was connected, and no matching Spotify crash report was available. The fixes address observed code paths; they do not establish the cause of the reported crashes or verify battery improvement on hardware.

## Findings and changes

- Metal device creation and per-letter texture uploads could run on the main thread as a word became active. Device/pipeline creation and texture uploads now use a dedicated resource queue. UIKit still rasterizes glyphs on the main thread, into one atlas per word.
- Each letter previously needed a texture bind and draw call, with new vertex data allocated each frame. Each word now has one atlas, one reusable vertex buffer and one draw call. Existing moving-letter geometry and karaoke masks still apply.
- A single render queue could stall all words behind one unavailable drawable. Independent submissions now run on a concurrent queue with at most twelve frames in flight across active and retired effects, and at most one per effect. Upload preparations are also bounded to twelve. Apple's [Metal drawable guidance](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html) documents drawable-pool blocking and recommends short drawable lifetimes; submissions acquire drawables late and use autorelease pools.
- UIKit's original letters remained visible under asynchronously positioned shader letters. Original ink now becomes transparent only after a successful shader frame, then returns when the shader stops. Intensity blends the static ink into the shader itself. Moving-letter glow is composed on the word surface.
- A boolean running flag could let older queued work return after pause/resume or seeking. Submission generations now reject stale work and completion callbacks. Resized words fall back to text; layout rebuilds create fresh effects.
- Shader updates are limited to 60 fps normally, 30 in Low Power Mode or fair thermal state, 15 at serious thermal state, and static text at critical thermal state. The shared lyrics display link retains its existing ProMotion behavior. Inactive/offscreen/paused lyrics and Reduce Motion use static text.
- Active budgets remain 48 glyphs / 512K atlas pixels and twelve surfaces / 2M surface pixels. A memory warning invalidates active effects and blocks new allocations for fifteen seconds. A currently invalidated word remains readable as static text; later words may allocate again after the cooldown. Temporary allocation-budget failures retry at half-second intervals while the word remains active.

## Measured results

An isolated UIKit app used the production renderer on the iOS 27.0 simulator on this Mac. The workload displayed five styles with moving letters plus joined Arabic text for twelve seconds, with 31 word replacements. Both runs recorded 73 successful effect creations, including initial setup and repeated lifecycle exercises. The committed renderer at `ec386a2` was the baseline. These are single-run CPU measurements, not physical iPhone GPU timings or end-to-end Spotify frame rates.

| Measurement | Baseline | Updated |
|---|---:|---:|
| Effect creation, p95 | 7.851 ms | 1.138 ms |
| Effect creation, maximum | 109.137 ms | 13.582 ms |
| Main-thread tick, p95 | 0.173 ms | 0.222 ms |
| Main-thread tick, maximum | 13.821 ms | 1.455 ms |
| Tick samples | 718 | 720 |

Creation p95 fell approximately 85%. Typical tick cost was slightly higher in the updated run; the large replacement-time spikes were reduced. Simulator variability and host scheduling affect these values. The harness uses white text without glow, so it does not measure the cost of animated backgrounds, glow, translation, or other Spotify UI. No GPU/energy profile or prolonged thermal test was performed.

## Validation

- `bash harness/lyrics-shaders/build.sh`: all five styles compiled and rendered on the Mac GPU; animation, deterministic seeking, premultiplied alpha, transparent regions, intensity mixing and frame-rate policy assertions passed.
- `bash harness/lyrics-shaders/preview.sh`: all styles and Arabic text, invalid input, budget fallback, repeated invalidation, pause/resume, original-ink restoration and cleanup with frames in flight passed on the iOS 27.0 simulator.
- The same preview deliberately delayed submissions and passed stale-frame rejection after pause/seek, recovery with fresh frames, resize fallback and memory-warning cleanup. The delay hook is compiled only into the harness.
- `bash scripts/check-layers.sh tweak/Sources` and `git diff --check` passed. The full release pipeline builds the production iPhoneOS code without test hooks. The current artifact and verification details are recorded in `HANDOFF.md`.
- Generated evidence is local and ignored by Git: `out/lyrics-shader-perf/baseline.json`, `performance.json`, `result.txt`, `stress-result.txt`; the baseline renderer snapshot is in that directory's `baseline/` folder.

## Device acceptance still required

Sign and install the performance IPA listed in `HANDOFF.md` on the iPhone 16e running iOS 27. Enable Redesigned UI and restart Spotify if changing looks. Open Mod Settings → Lyrics → Adjust → Lyrics shader and check all five styles against Classic using the same timed-lyrics track.

1. Watch moving letters for doubled edges or flicker. Pause/resume, seek backward and forward, switch tracks quickly, rotate, and leave/reopen lyrics. Text must stay readable through each transition.
2. Repeat with Low Power Mode and Reduce Motion, then background/foreground the app and lock/unlock. Reduce Motion should retain static text; Low Power Mode should reduce shader updates.
3. Compare several minutes of the same playback conditions with Classic and a shader, keeping brightness and background style fixed. Check stutter and heat. Use Instruments for frame pacing, allocations and energy if available; simulator results cannot supply these measurements.
4. If Spotify crashes or freezes again, retain its timestamp and matching crash report or hang trace for diagnosis. Crash elimination is not established by the harness.
