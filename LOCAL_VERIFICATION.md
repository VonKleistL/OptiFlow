# OptiFlow local verification — 2026-10-18

## Deliverable

- Project: `OptiFlow.xcodeproj`, shared `OptiFlow` scheme.
- Application: `/Users/lukeedgar/Desktop/easy-move-resize/build/OptiFlow/Build/Products/Release/OptiFlow.app`.
- Identity: OptiFlow 1.8.2, `org.VonKleistL.OptiFlow`, developer VonKleistL.
- Native arm64 Release build, ad-hoc signature verified with `codesign --verify --deep --strict`.
- The shipping implementation is entirely Swift 6, using AppKit and Apple frameworks. No external packages or runtime dependencies were downloaded or added.
- The installed `/Applications/Easy Move+Resize.app` remains version 1.8.1 and was not overwritten, stopped, or replaced. Its executable SHA-256 before and after the work was `97e09e40357b2d780c648d51d63cc6bddd4ccb088b05c17ffddf100164d2e6f2`.
- No branches, commits, remote operations, pull requests, workflow changes, or system accessibility configuration changes were made.

## Icon update and DMG — 2026-10-18

- Replaced all ten app-icon sizes and six menu-icon appearance/scale variants with `/Users/lukeedgar/Pictures/OF.png`, preserving the supplied colors and transparency. The 1024-pixel app asset is the original PNG; smaller assets use local `sips` resizing.
- Incremental native arm64 Release build succeeded. No Swift code or gesture behavior changed. The existing Xcode App Intents metadata-skipped warning remained.
- Loaded the compiled menu asset from the app bundle and rendered it in Aqua and Dark Aqua. Both retain their 16-point size and original colors; each rendered channel differed from the resized source by at most 1/255. Evidence: `build/evidence/icon-validation.txt` and `menu-icon-{light,dark}.png`.
- Updated `/Applications/OptiFlow.app` after a graceful quit, verified its signature and byte-for-byte bundle equality with the new build, and relaunched it successfully. Previous OptiFlow bundle: `build/Packaging/Previous-OptiFlow.app`. The installed Easy Move+Resize app was not replaced.
- Created `/Users/lukeedgar/Desktop/OptiFlow-1.8.2.dmg` containing `OptiFlow.app` and an `Applications` shortcut. Verified the disk-image checksum, mounted it read-only, checked the packaged app signature, compared every bundle file to the build, and detached it successfully.
- DMG SHA-256: `57a9e3adae115ad6bfaefad13e18c30af3f0d70a863335662e6a0010819f2583`. Packaging evidence: `build/evidence/dmg-*.log`, `dmg-mount.plist`, and `dmg-sha256.txt`.
- The app remains ad-hoc signed and is not notarized. No full gesture tests were rerun for this asset-only update; the performance verification below describes the preceding implementation work.

## Baseline and root-cause evidence

The checkout's Info.plist declared 1.8.0; the installed application declares 1.8.1. The benchmark baseline is the unchanged local Objective-C source, not instrumentation of the installed 1.8.1 binary. Exact original sources and the baseline build remain under `build/evidence/` and `build/Baseline/`.

The entire mouse-down, drag, resize, mouse-up, modifier, event-tap, preference, display, and teardown path was traced. The original implementation:

1. Performs synchronous `AXUIElementSetAttributeValue` calls on the event-tap/main thread. Injecting a nominal 12 ms AX delay made a single callback take 15.09 ms; a sustained comparison is below. Actual native-target runs also exhibited long callback tails.
2. Resets its throttle timestamp after the AX call returns. Every update therefore costs AX latency **plus** a refresh interval, followed by waiting for another mouse event. This is directly reflected in the slow-AX benchmark's approximately 32.63 ms write spacing at nominal 60 Hz.
3. Only flushes during dragged events. A quick drag ending within one refresh interval produced zero writes in the original regression harness.
4. Returns immediately on missing modifiers, leaving tracking active. The modifier-release regression failed on the original code.
5. Accumulates delta fields, truncates resize deltas, and leaves invalid/failed target paths insufficiently guarded. It also uses a startup-only fastest-display interval, overscheduling displays slower than 60 Hz, rather than selecting the display under the pointer.

The original regression harness failed the final-flush, modifier-cleanup, and blocked-callback checks before performance code was replaced. The original preference XCTest passed unchanged.

## Implementation

- `DragController.swift` owns input and gesture state on the main actor. Drag/flags/up callbacks perform no AX operations, preference reads, or display queries. They update a constant-size latest-position mailbox. Captured mouse-up is consumed even after modifier release, preventing orphan drag/up events reaching the target. Cancellation, application termination, event-tap interruption, sleep, session deactivation, and quit all end the gesture.
- `DragWriter.swift` owns AX work on one serial queue. There is one pending frame per gesture, one write operation at a time, and no FIFO of mouse movement events. A demand-driven, one-shot dispatch timer has no periodic idle wakeups. Start-to-start pacing uses the pointer's display interval and an exponentially smoothed measurement of AX write latency. A slow write consumes the interval rather than adding another full interval afterward.
- Final mouse-up coordinates bypass pacing. Finishing/restoration is enqueued before the next gesture's preparation, so rapid gestures cannot restore accessibility state out of order. Failure cancels scheduled updates and runs the same cleanup.
- `DragGeometry.swift` derives movement from absolute cursor displacement, retaining fractional coordinates and supporting negative monitor coordinates. The original nine resize regions remain. Resize size is applied before anchored position; left/top resizing reads back accepted size to respect application minimums and keep the opposite edge fixed.
- `AXWindowTarget.swift` performs guarded hit testing once on mouse-down. This remains synchronous so disabled apps, desktop clicks, and unsupported windows pass through. Acquisition IPC uses a 50 ms timeout per AX element/call; worker-owned window/application elements use 100 ms. These affect this process's AX client only.
- Display rectangles and refresh intervals are cached and updated on screen-configuration notifications, with AppKit-to-AX coordinate conversion. The interval is selected from the display under the pointer, including lower/higher refresh rates; no idle display polling was introduced.
- Preferences retain the original `userPrefs` suite and keys. Modifier selection, exact modifier matching, middle-button resize, resize-only, bring-to-front, per-app exclusions, disable/reset, and menus are retained. At initial verification, all 19 original image asset files were compared byte-for-byte; app and menu artwork was subsequently replaced as documented above. UI labels, project/target names, bundle identity, and Swift headers now use OptiFlow/VonKleistL. The required upstream MIT notice remains intact and is included in the app.

### AXEnhancedUserInterface

The proposed approach was evaluated from the supplied description without fetching or merging PR #133. The available target reported `AXEnhancedUserInterface = false`; disabling it is therefore not an established explanation or improvement for that target's current state.

The local equivalent only changes a supported, writable boolean that was originally **true**. False, absent, unsupported, and read-only states are left alone. Restoration is recorded before attempting to disable, including an ambiguous timeout. Normal end, cancellation, preparation/write error, interrupted gesture, target termination, and graceful quit run cleanup. Restoration retries `cannotComplete` at most three times; a terminated AX application has no remaining state to restore. Other failures surface through the status-item tooltip and logging. There is no idle restoration polling.

This attribute is undocumented and per application. A force-killed OptiFlow process or a persistently unresponsive target cannot provide a guaranteed restoration transaction; a failed bounded restoration is reported, not silently treated as success. No system-wide accessibility feature was disabled.

## Tests and build

Environment: Apple M5 MacBook Air, 24 GB RAM, macOS 27.2 (26B5112a), Xcode 27.2 (27B5028f), arm64. One 1920×1243 logical display was exposed, reporting 60 Hz and a 0.016666 s minimum refresh interval.

The unchanged Xcode project initially failed because its macOS 10.13 target is outside this Xcode's supported 12.0–27.2 range. The baseline build used a 12.0 command-line override. OptiFlow declares macOS 12.0; only the XCTest target declares 14.0 because this Xcode's XCTest libraries require it. Older OS runtime compatibility was not exercised.

- Original Objective-C preference test: **1 passed, 0 failed** (`build/evidence/legacy-tests.txt`).
- Swift suite: **16 passed, 0 failed**, covering preferences, all resize regions, negative/fractional coordinates, clamp/anchor math, blocked AX isolation, latest-position coalescing, final flush, modifier release, orphan events, exclusions, button/mode selection, rapid gesture ordering, errors, conditional enhanced-UI state/restoration, termination, shutdown, and loading the existing menu nib with the Swift delegate.
- Final run with **Thread Sanitizer**: **16 passed, 0 failed**, no Thread Sanitizer race reports (`build/evidence/thread-sanitizer-tests.log`).
- Release build and Xcode Analyze action succeeded. No Swift source compiler warnings remained. Xcode emitted its benign App Intents metadata-skipped warning because the app does not use AppIntents. Sandbox attempts also produced Xcode service diagnostics; the successful XCTest runs used the local test services outside that sandbox, without changing permissions.
- The new Release app launched and exited cleanly with status 0 (`build/evidence/event-tap-smoke.txt`). This checks launch/teardown only. Global mouse injection was skipped because the installed utility is running; it was left untouched.
- Release signature verifies; the binary is arm64 and does not link sanitizer runtimes. No distribution certificate or notarization was used.
- Swift ARC owns the AX references. Queue-confined mutable state and the locked mailbox were reviewed; the active timer's handler is cleared at cleanup to break its intentional session-retention cycle. No heap-leak capture was performed.

Reproducible native build/test commands are in `readme.md`. Tests compile the same production Swift files into a hostless XCTest bundle; they do not install an input event tap or prompt for Accessibility permission.

## Measured performance

These are **scripted API/input timings, not rendered FPS**. Each performance run lasts two seconds, with a nominal 1 ms input producer and a 20-point horizontal oscillation. The original harness calls the unchanged event callback; the Swift harness calls the production controller and writer, including synthetic CGEvent construction. The wrappers record write start times and durations. Neither benchmark posts those synthetic events to global input. Producer wakeups and OS scheduling vary, so callback counts differ. Positions and sizes are restored after each native run.

### Controlled slow-AX simulation

A requested 12 ms sleep simulates a blocking AX call; actual mean sleeps were approximately 14.3 ms on this Mac.

| Metric | Original local source | Swift OptiFlow |
|---|---:|---:|
| Nominal 60 Hz: median write interval | 32.625 ms | 17.099 ms |
| Nominal 60 Hz: input callback p95 | 13.653 ms | 0.005 ms |
| Nominal 120 Hz: median write interval | 23.853 ms | 14.896 ms |
| Nominal 120 Hz: input callback p95 | 15.031 ms | 0.007 ms |

The 60 Hz median write interval fell by approximately 47.6%. The 120 Hz simulation correctly remained limited by actual AX latency; it does not imply 120 displayed frames per second. Raw files: `build/evidence/baseline-synthetic.txt`, `swift-synthetic.txt`, and `swift-pacing.txt`. Synthetic no-delay scheduling was also exercised at 60/120 Hz, without claiming high-refresh hardware validation.

### Available native target

The running application is named **ChatGPT** and is installed at `/Applications/ChatGPT.app`, but its bundle identifier is **`com.openai.codex`**. A running `com.openai.chat` application was not available. The results apply to the observed app/window; they do not establish the behavior of a separate official ChatGPT build. The available window was not guaranteed foreground/visible, further preventing visual frame-rate claims.

Three sequential original/Swift pairs produced:

| Metric | Original range, 3 runs | Swift range, 3 runs |
|---|---:|---:|
| Input callback p95 | 0.117–0.255 ms | 0.008–0.009 ms |
| Maximum input callback | 12.646–39.565 ms | 2.419–3.748 ms |
| Median write interval | 17.792–17.964 ms | 17.576–17.653 ms |
| Mean AX operation time | 0.698–1.109 ms | 1.352–1.801 ms |

Individual AX operations did **not** get faster in these runs. Their blocking cost moved off input processing; ordinary write pacing improved only slightly. The severe visual stuttering was not reproduced or visually measured in this environment.

The final native window-position errors were 0.119, 0.822, and 0.107 points. A separate native resize run had 0 position error and 0.063-point size error, with a 17.616 ms median write interval. These are within the target's pixel rounding. The requested final values were read back before restoring the original window geometry. Raw paired results: `build/evidence/final-comparison.txt`.

## Remaining verification limits and macOS behavior

- No manual dragging, compositor FPS capture, physical 120 Hz test, or physical multi-monitor test was performed. Higher-refresh scheduling, negative screen coordinates, and resize behavior have automated coverage only where described above.
- The installed utility remains running, so the replacement's full global hotkey/mouse interception path was not exercised. Startup, nib wiring, input logic, serial writer, and native AX updates were checked separately.
- AX remains synchronous IPC to the target application. One-time mouse-down eligibility checks can still block briefly. WindowServer scheduling, application animations/minimum sizes, and fractional-point rounding remain outside the utility's control. Resize sometimes requires separate size/readback/position messages; the public API does not make these an atomic frame update.
- No specific idle CPU or energy improvement was measured. The implementation contains no periodic idle update timer or background service.
- OptiFlow has a new bundle identity and needs its own macOS Accessibility approval when launched independently. The installed app's approval is not copied or changed.
- The build is ad-hoc signed and was not notarized or tested as a downloaded distribution.

Relevant official API references: [AX setter and failure behavior](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue), [AX messaging timeout scope](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout), and [display minimum refresh interval](https://developer.apple.com/documentation/appkit/nsscreen/minimumrefreshinterval). The current installed SDK headers were also consulted.
