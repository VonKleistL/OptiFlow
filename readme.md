# OptiFlow

Native macOS window movement and resizing, maintained locally by **VonKleistL**.
Written in Swift 6 with AppKit and the macOS Accessibility API. This local build is
version **1.8.2** and derives from Easy Move+Resize. The original MIT license is
retained in [LICENSE.txt](LICENSE.txt) and included in the application bundle.

## Usage

- Hold **Cmd + Ctrl** and drag with the **left mouse button** anywhere inside a window to move it.
- Hold the same modifiers and drag with the **right mouse button** to resize it.
  The clicked third of the window selects the resize edges; the center selects neither edge.
- The menu keeps the original modifier toggles, middle-button resize, resize-only
  mode, bring-to-front option, per-application exclusions, disable switch, and reset.
- Existing preferences in the `userPrefs` suite are retained.
- OptiFlow needs its own Accessibility permission. Grant it through macOS when
  launching the replacement; the installed application is not overwritten.

## Local build and tests

Requires macOS 12 or newer and a local Xcode with Swift 6. The test runner in the
installed Xcode requires macOS 14 or newer. No external packages are used.

```sh
xcodebuild -project OptiFlow.xcodeproj -scheme OptiFlow -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/OptiFlow \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  ARCHS=arm64 CODE_SIGN_IDENTITY=- build

xcodebuild -project OptiFlow.xcodeproj -scheme OptiFlow -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/OptiFlow \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  ARCHS=arm64 CODE_SIGN_IDENTITY=- test
```

Output: `build/OptiFlow/Build/Products/Release/OptiFlow.app`.
This is a locally signed application, without distribution signing or notarization.
The existing release automation is untouched and is not used for this local build.


