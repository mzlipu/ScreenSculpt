# Contributing to ScreenSculpt

## Getting set up

```bash
brew bundle          # xcodegen, swiftlint, create-dmg
make bootstrap       # generates ScreenSculpt.xcodeproj
make test            # runs headlessly — no permissions, no window server
```

You need Xcode 26 or later. On a fresh machine you will also need:

```bash
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

Without the second one, `xcodebuild` fails to load a required plug-in. Note that
`git`, `swift` and every `xcrun` tool on macOS are Xcode shims, so an unaccepted
licence blocks all of them, not just compilation.

`ScreenSculpt.xcodeproj` is **generated and gitignored**. Edit `project.yml` and
re-run `make generate`. Never commit the `.xcodeproj` — it is an opaque plist
that produces merge conflicts nobody can resolve.

## The two rules that matter

Everything else is ordinary Swift style enforced by SwiftLint. These two are
architectural, and a PR that breaks them will fail CI.

### 1. Lengths carry their unit in the type

`ImagePx`, `LogicalPt` and `ViewPt` are distinct types. The compiler rejects
mixing them, and converting requires naming a `PixelScale`:

```swift
let a: ImagePx = 10
let b: LogicalPt = 10
let c = a + b                     // compile error, by design
let d = a + b.inPixels(.x2)       // fine — the conversion is visible
```

This exists because silently treating a logical point as a device pixel is *the*
defining bug of this problem domain, and it reproduces only on hardware you
probably don't own — a mixed 2×/1× multi-display setup, or a display positioned
above the primary one.

Reach for `.value` only at a framework boundary, and prefer `.cgFloat` /
`.cgRect` when handing something to CoreGraphics.

### 2. Compute modules must not import AppKit

`SSGeometry`, `SSImaging`, `SSAnnotations`, `SSStitch`, `SSMeasure`,
`SSRecognition`, `SSExport` and `SSPersistence` stay headless.

SwiftPM does **not** enforce this — any macOS target can import any system
framework regardless of its declared dependencies. We verified that by compiling
`import AppKit` inside `SSStitch`, which succeeded. So a SwiftLint custom rule
(`no_appkit_in_compute_modules`) is the actual enforcement.

The reason is testability. The moment the stitcher can read `NSScreen.main`, its
correctness depends on the machine the test runs on, and multi-display bugs stop
being reproducible in CI. Screen state lives in `SSPlatform` and reaches compute
code as a parameter.

## Testing

The hard logic is deliberately written as pure functions over synthetic inputs —
the correlator, the sticky-band detector, coordinate conversions, colour maths,
filename templates, the PNG encoder — so all of it is unit-testable with no
window server and no TCC grant.

```bash
make test                                    # everything
swift test --package-path Packages/ScreenSculptKit --filter SSGeometryTests
```

If you are adding to a compute module and find yourself unable to test it
headlessly, that is a signal the module boundary is wrong, not that the test is
hard to write.

Some things genuinely need real hardware and cannot run in CI: capture across
mixed-scale displays, permission flows, global hotkeys, scroll driving. Test
those by hand and say so in the PR.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), because the
changelog is generated from them:

```
feat(measure): add APCA contrast alongside WCAG 2
fix(capture): detect stale Screen Recording grant after app is moved
docs(readme): explain the unsigned-install trade-off
```

Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `ci`, `chore`.

### Sign your commits off

```bash
git commit -s -m "fix(geometry): flip against the union, not the primary display"
```

That adds a `Signed-off-by:` line asserting the
[Developer Certificate of Origin](https://developercertificate.org/). There is no
CLA and no copyright assignment — you keep your copyright.

## Pull requests

- Branch from `main`, keep it short-lived: `feat/scroll-stitcher`, `fix/ruler-retina`.
- `make test` and `swiftlint --strict` must pass.
- PRs are **squash merged**, which keeps history linear. That is load-bearing:
  the app's build number is `git rev-list --count HEAD`, and Sparkle compares it
  numerically to decide whether an update exists.
- Fork PRs build unsigned. CI runs with `CODE_SIGNING_ALLOWED=NO` because forks
  correctly receive no secrets — that is not a bug to work around.

## Good first issues

Look for `good first issue`. The colour and contrast maths in `SSMeasure` is a
pleasant place to start: it is pure, self-contained, and has published reference
vectors to test against.

## What is unlikely to be merged

- **A Mac App Store build.** The App Sandbox makes synthesized `CGEvent` scroll
  and `AXUIElement` observation impossible, so scrolling capture cannot work
  inside it.
- **Telemetry or analytics of any kind.** The app holds Screen Recording
  permission; "we collect nothing" is a promise worth more than the data.
- **A hosted upload service.** S3 upload is bring-your-own-bucket precisely so
  there is no server, no account and no operating cost.
- **Windows or Linux support.** The whole thing is ScreenCaptureKit, Vision,
  AppKit and Core Graphics.
