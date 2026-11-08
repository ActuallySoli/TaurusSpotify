# Lyrics shaders

`bash harness/lyrics-shaders/build.sh` compiles the production Metal source on the Mac's GPU and checks all five styles for distinct animated output, deterministic seeks, premultiplied glyph alpha, transparent backgrounds and intensity scaling.

`bash harness/lyrics-shaders/preview.sh` builds and launches an isolated UIKit app on the booted iOS simulator. It uses the production renderer, draws all five styles with moving letters plus joined Arabic text, and checks invalid input, the mask budget, repeated invalidation, pause/resume, and cleanup with GPU frames in flight. After three seconds the app writes `Documents/result.txt` in its simulator data container and prints PASS to the device log. Use `xcrun simctl get_app_container booted com.taurus.lyricsshaders.harness data` to locate it.

The five Metal fills are independently authored recreations of the visual styles named on Chroma's public lyrics preview (https://chroma.pw/). They are not extracted Chroma shader source and do not load Workshop content.

Device verification still needed: install the release on an iPhone running iOS 26+, enable Redesigned UI, open Mod Settings → Lyrics → Adjust → Lyrics shader, select each style, and play timed lyrics in portrait and landscape. Check the word sweep, letter motion, pause/resume, seeking, changing tracks and Reduce Motion. Classic returns to the original text. A hardware performance/battery comparison is not covered by this harness.
