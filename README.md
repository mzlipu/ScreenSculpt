<div align="center">

# ScreenSculpt

**A fast, native macOS screenshot tool for people who care about pixels.**

Scroll a whole page into one image. Measure the gap between two elements to the
pixel. Read a colour and check its contrast. Pull text out of anything on screen.

[![CI](https://github.com/OWNER/ScreenSculpt/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/ScreenSculpt/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](#requirements)

</div>

> **Status: v0.1.0, early.** Area / fullscreen / window capture work, saving to
> disk and the clipboard work. The editor, annotation tools, measurement, OCR and
> scrolling capture do not exist yet — see [the roadmap](#roadmap).
>
> **ScreenSculpt is a menu bar app with no window.** After launching it, look for
> the viewfinder icon at the top-right of your screen. See
> [docs/USAGE.md](docs/USAGE.md).

---

## Why

The stock macOS screenshot tool captures and crops, and stops there. It cannot
scroll a long page into a single image, cannot tell you the distance between two
elements, cannot read a colour or check its contrast ratio, and cannot pull text
out of a picture.

Those four things are what ScreenSculpt is for. Everything else it does exists to
support them.

## Requirements

- macOS 14 (Sonoma) or later
- Apple silicon or Intel — one universal binary

macOS 14 is a hard floor, not a preference: `CGWindowListCreateImage` and
`CGDisplayCreateImage` are *obsoleted* as of macOS 15, so ScreenCaptureKit is the
only capture path available, and its screenshot API starts at 14.0.

## Installing

> No public release yet — the URLs below are placeholders. To build a local
> `.dmg` right now: `make dmg`, which writes `build/ScreenSculpt-<version>.dmg`.
> Full walkthrough in [docs/USAGE.md](docs/USAGE.md).

ScreenSculpt is **not signed with a paid Apple certificate**. That is a
deliberate trade — the project has no revenue and an Apple Developer membership
costs $99/yr — and it has two honest consequences you should know about before
installing:

1. **A browser download will be blocked by Gatekeeper** with "ScreenSculpt is
   damaged and can't be opened." It isn't damaged; macOS says that for anything
   unsigned that arrives with a quarantine flag. The fix is System Settings →
   Privacy & Security → **Open Anyway**.
2. **After enabling Screen Recording you must reopen the app.** macOS applies
   that grant only when a process starts, so approving it while ScreenSculpt is
   running changes nothing until you restart. ScreenSculpt detects this exact
   case and offers a Relaunch button.

   The grant itself now *persists* across updates: builds are signed with a
   self-signed certificate, giving a stable designated requirement rather than
   the per-build `cdhash` that ad-hoc signing produces.

The `curl` install avoids the first problem entirely, because quarantine is
attached by the *downloading application* and `curl` doesn't attach it:

```bash
curl -fsSL https://dl.screensculpt.app/ScreenSculpt-latest.dmg -o /tmp/ss.dmg && \
  hdiutil attach -nobrowse -quiet /tmp/ss.dmg && \
  cp -R "/Volumes/ScreenSculpt/ScreenSculpt.app" /Applications/ && \
  hdiutil detach -quiet "/Volumes/ScreenSculpt" && \
  open /Applications/ScreenSculpt.app
```

Or via Homebrew — `--no-quarantine` is required, because Homebrew applies the
quarantine flag by default:

```bash
brew install --cask --no-quarantine OWNER/screensculpt/screensculpt
```

Every release publishes a SHA-256 next to the download. Since there is no
notarization ticket, that checksum is the only integrity signal available —
please check it:

```bash
shasum -a 256 ScreenSculpt-1.0.0.dmg
```

## Permissions

ScreenSculpt asks for two things, and never at launch — only the first time you
use a feature that needs them.

| Permission | Needed for | Notes |
|---|---|---|
| **Screen Recording** | Every capture, and OCR | Unavoidable: macOS gates all screen pixels behind it |
| **Accessibility** | Scrolling capture only | Used to send scroll events to the window you are capturing. **Manual scrolling capture needs no Accessibility permission at all**, if you would rather not grant it |

Screenshots never leave your machine. There is no account, no telemetry, no
analytics and no hosted upload service. If you configure S3 upload, it is *your*
bucket and your credentials, stored in the macOS Keychain.

## Roadmap

| Phase | Contents | Status |
|---|---|---|
| 1a | Area / fullscreen / window capture, save, clipboard | **done** |
| 1b | Editor window, crop, zoom, nine annotation tools | in progress |
| 2 | Measurement, colour, contrast, auto-fit selection | |
| 3 | Scrolling capture | |
| 4 | OCR, QR, text-only redaction | |
| 5 | Backdrop, pinning, GIF, S3 upload | |
| 6 | Release pipeline, website, Homebrew | |

## Building from source

```bash
brew bundle          # xcodegen, swiftlint, create-dmg
make bootstrap       # generates ScreenSculpt.xcodeproj from project.yml
make test            # headless: no window server, no permissions needed
make run
```

`ScreenSculpt.xcodeproj` is **generated and gitignored**. It is an opaque plist
that produces unresolvable merge conflicts, so `project.yml` is the source of
truth — edit that and re-run `make generate`.

Locally built apps are never quarantined, so a source build has none of the
Gatekeeper friction described above.

### Layout

```
App/                      NSApplication entry point, menus, composition root
Packages/ScreenSculptKit/ all the logic, as ~17 SPM targets
  SSGeometry              unit-tagged coordinate types  ← start here
  SSImaging               RasterImage and the pixel pipeline
  SSAnnotations           the annotation object model
  SSDocument / SSRender   document state, undo, and the renderer
  SSCapture / SSStitch    ScreenCaptureKit, scroll driving, stitching
  SSMeasure               ruler, edge detection, colour, contrast
  SSRecognition           Vision text and barcode
  SSPlatform / SSHotKeys  TCC, displays, URL scheme, global hotkeys
  SS*UI                   AppKit windows and views
```

Two conventions worth knowing before your first patch:

**Lengths carry their unit in the type.** `ImagePx`, `LogicalPt` and `ViewPt` are
distinct types, and the compiler rejects mixing them. Converting requires naming
a `PixelScale`. This is deliberate — silently treating a logical point as a
device pixel is the defining bug of this problem domain, and it only reproduces
on hardware the author doesn't own.

**Compute modules must not import AppKit.** SwiftPM does *not* enforce this (any
macOS target can import any system framework), so a SwiftLint rule does. Screen
state belongs in `SSPlatform` and reaches the compute modules as a parameter,
which is what keeps the stitcher and the measurement code testable headlessly.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Commits need a
[DCO](https://developercertificate.org/) sign-off (`git commit -s`) — there is no
CLA and no copyright assignment.

## Licence

Source is [Apache-2.0](LICENSE). Apache rather than MIT for the explicit patent
grant — image stitching, edge detection and contrast computation are
patent-dense areas — and for §6, which reserves the project name.

The brand assets in `Assets/brand/` are **not** covered by that licence; see
[ASSETS-LICENSE](ASSETS-LICENSE). Fork the code freely, but ship it under your
own name and icon so users can tell the two apart.
