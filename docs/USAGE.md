# Using ScreenSculpt

> **v0.1.0 — early.** Capture, the editor, nine annotation tools, global
> shortcuts and settings all work. Measurement, OCR and scrolling capture do not
> exist yet.

## Installing

Open `build/ScreenSculpt-0.1.0.dmg` and drag **ScreenSculpt.app** onto the
Applications folder.

**Keep exactly one copy.** Do not leave a second one in Downloads or on the
Desktop. macOS ties the screen-recording permission to a specific copy of an
app, so having two is the most common way to end up with screenshots that come
back black.

## First launch

### 1. It has no window

ScreenSculpt is a **menu bar app**. After opening it, look at the top-right of
your screen for a viewfinder icon:

```
                                    ⌘  🔍  🔋  📶  Tue 10:42
                                        ↑
                                 ScreenSculpt
```

There is no Dock window and no main window. Clicking that icon is how you use
it. If you don't see it, your menu bar may be full — quit a few other menu bar
apps and try again.

### 2. Gatekeeper will block it once

The first time you open it, macOS says:

> **"ScreenSculpt is damaged and can't be opened. You should move it to the
> Trash."**

It is not damaged. ScreenSculpt is not signed with a paid Apple certificate, and
macOS shows that exact wording for any unsigned app that arrived through a
browser. To open it anyway:

1. **System Settings → Privacy & Security**
2. Scroll down to **Security**
3. Next to *"ScreenSculpt was blocked from use"*, click **Open Anyway**
4. Authenticate, then open ScreenSculpt again

Once per version, not once per launch.

> On macOS 15 and later, the old Control-click → Open trick no longer works. The
> Open Anyway button in Settings is the only route.

### 3. Grant Screen Recording on your first capture

The first capture will fail and show a dialog. That is expected — macOS gates
every screen pixel behind this permission and no app can bypass it.

1. Click **Open System Settings** in the dialog
2. Enable **ScreenSculpt** under Screen & System Audio Recording
3. **Quit and reopen ScreenSculpt** — the grant only applies to a fresh process

## Taking a screenshot

Click the menu bar icon and pick one, or use the shortcut while ScreenSculpt is
frontmost:

| What | Shortcut | What it does |
|---|---|---|
| **Capture Area** | `⌃⇧⌘4` | Freezes the screen, drag to select |
| **Capture Fullscreen** | `⌃⇧⌘3` | The display your cursor is on |
| **Capture Active Window** | `⌃⇧⌘5` | The frontmost window, shadow trimmed |

Every capture **opens in the editor**. Nothing is written to disk until you ask
— press `⌘S` to save to `~/Pictures/Screenshots`, or `⌘C` to copy.

## The editor

| Action | How |
|---|---|
| Select a region | Drag. Shift-drag for a square |
| Crop | Select, then **Enter** (or `⌘K`) |
| Undo / redo | `⌘Z` / `⇧⌘Z` |
| Reset crop | Edit → Reset Crop |
| Zoom in / out | `⌘+` / `⌘-`, or `⌘`-scroll, or pinch |
| Zoom to fit | `⌘1` |
| Actual size (1:1) | `⌘0` |
| Zoom to selection | `⌘2` |
| Pan | Right-drag, or hold **Space** and drag, or two-finger scroll |
| Nudge selection | Arrow keys (`⇧` for 10px) |
| Resize selection | `⌘`+arrows (`⇧` for 10px) |
| Grow / shrink selection | `[` and `]` |
| Copy / Save | `⌘C` / `⌘S` |

The title bar shows the size in both pixels and points, plus the zoom level.

## Annotation tools

Pick one from the toolbar, or press its letter. Press the same letter again — or
`V`, or Escape — to go back to selecting.

| Tool | Key | Notes |
|---|---|---|
| Arrow | `A` | Drag the middle handle to bend it into an arc |
| Line | `L` | |
| Rectangle | `R` | Shift-drag for a square |
| Oval | `O` | Shift-drag for a circle |
| Text | `T` | Click, then type. Enter commits, Escape discards. Double-click a label to re-edit it |
| Freehand | `D` | Smoothed as you draw |
| Highlighter | `H` | Multiplies, so overlapping passes darken |
| Blur | `B` | Pixelate, blur or solid block |
| Counter | `N` | Click to drop a numbered badge; numbering continues automatically |

Once placed, everything stays editable:

| Action | How |
|---|---|
| Select | Click it. The topmost object wins |
| Move | Drag. Alignment guides appear when edges line up |
| Reshape | Drag a handle |
| Duplicate | Option-drag, or `⌘D` |
| Delete | Select and press Delete |
| Suspend snapping | Hold `⌘` while dragging |
| Cancel a drawing | Escape |

**Annotations are objects, not paint.** They stay editable indefinitely, and the
pixels underneath survive — including under a blur.

### Blur and Merge are not the same thing

They are easy to confuse because **after merging, the picture looks identical**.

**Blur** (`B`) is a *tool*. It adds an object that hides a region. The pixels
underneath are untouched — which is why you can still move the blur, resize it,
change its mode, or delete it. It also means the hidden pixels are **still in the
document**.

**Merge** (`⌘E`) is a *one-shot action*. It bakes every annotation permanently
into the pixels and removes the objects. Afterwards nothing is editable and the
hidden pixels are genuinely gone.

| | Blur | Merge |
|---|---|---|
| What it is | A tool you draw with | An action you invoke once |
| Affects | One region | Every annotation at once |
| Pixels underneath | Preserved | Destroyed |
| Still editable after | Yes | No |
| Visible change | Yes | **None** |

The title bar shows the object count, so you can watch it drop to nothing when
you merge — that is the only on-screen evidence the action did anything.

**You rarely need to merge by hand.** Saving and copying flatten automatically,
so an exported file never leaks what a blur is covering. Merging manually is for
when you want to be certain the live document is clean, or to stop yourself
nudging a blur out of place later.

Blur offers three modes. **Pixelate** and **solid** discard the original pixels
outright. Plain **blur** at a small radius is in principle partially reversible,
so pixelate is the default for anything you actually need hidden.

**Zoom past 100% and the image switches to nearest-neighbour**, so you see real
pixels rather than a smoothed approximation of them. Past 16× a **pixel grid**
fades in. This is the point of the whole app — at 3200% a one-pixel line should
be a clean 32×32 square aligned to the grid, not a blurry smear.

If a capture spanned two displays with different scale factors, the title bar
says **"measurements unavailable"**. That is deliberate: no single
pixels-per-point conversion is correct for such an image, so the app withholds
the number rather than printing one that is wrong for half the picture.

### While selecting an area

- **Drag** to select. The size is shown in both points and pixels.
- **Shift-drag** constrains to a square.
- A **magnifier** follows the cursor at 8×, with the exact pixel outlined in
  red, so you can land on a boundary precisely.
- **Escape** or **right-click** cancels.

The screen is frozen while you select, so animations, hover states and video
cannot move under your marquee.

### Shortcuts

These work **anywhere**, in any application — they do not need ScreenSculpt to
be frontmost. Change them in Settings → Shortcuts.

The defaults deliberately add Control, because macOS reserves `⇧⌘3`, `⇧⌘4` and
`⇧⌘5` for its own screenshot tool and would win silently if ScreenSculpt
registered them. The recorder refuses those, refuses combinations already used
by another ScreenSculpt command, and refuses anything without `⌘`, `⌃` or `⌥`
(which would otherwise fire while you type).

## Settings

Menu bar icon → **Settings…**, or `⌘,`.

| Pane | What is there |
|---|---|
| **General** | Screenshots folder, PNG/JPEG/automatic format, JPEG quality, Retina downscaling, filename template, what happens after a capture, window-capture background, launch at login, pointer visibility |
| **Shortcuts** | All seven global shortcuts, with conflict detection |
| **Editor** | Default zoom, pixel grid, always-on-top, what Escape does |
| **Advanced** | OCR language, scrolling-capture limits, menu bar and Dock icons, confirmation style, `screensculpt://` automation, reset |
| **Permissions** | Live status for both permissions, with the recovery action for each, plus a diagnostics report you can copy into a bug report |

**Every setting is also a `defaults` key**, including ones with no UI:

```bash
defaults write app.screensculpt.ScreenSculpt saveFormat png
defaults write app.screensculpt.ScreenSculpt filenameTemplate "shot-%Y-%m-%d"
```

Changes are picked up live — no relaunch needed.

## Troubleshooting

**Screenshots are black, or the app says macOS "is not honouring" the
permission.** This is a stale permission record, and it happens when the app is
moved, updated, or duplicated after being approved. Use **Check Permissions…**
in the menu — it detects this case specifically and will list any duplicate
copies it finds. The fix:

1. System Settings → Privacy & Security → Screen & System Audio Recording
2. Select ScreenSculpt, click **−** to remove it
3. Click **+**, add it back from /Applications
4. Quit and reopen ScreenSculpt

**The permission disappears after every update.** Fixed, and verified across an
update. Ad-hoc signing gave a designated requirement of `cdhash H"..."` which
changes with every build, so macOS quietly stopped honouring the grant while
still showing a ticked box. Builds are now signed with a self-signed certificate,
giving a stable `identifier + certificate` requirement. Run `make cert` once;
every build picks it up.

**`--diagnose` says permission is denied, but the app works.** Expected. TCC
attributes a permission request to the "responsible process", which for a binary
started from a shell is your *terminal*, not ScreenSculpt. The report says so
when it detects a tty. For a true reading:

```bash
open -n -a ScreenSculpt --args --diagnose
cat ~/Library/Logs/ScreenSculpt-diagnostics.txt
```

**It asks for permission even though Settings shows it enabled.** macOS applies a
screen-recording grant only when an app *starts*. If you approved it while
ScreenSculpt was already running, the running process still cannot capture. Quit
and reopen — ScreenSculpt detects this case and offers a **Relaunch** button.

**Nothing happens when I press the shortcut.** Either ScreenSculpt isn't
frontmost (see above), or another app owns that combination. Use the menu.

**I can't find the app after installing.** It is in the menu bar, not the Dock,
and it has no window. Spotlight can launch it but won't show a window either.

## What's next

Roughly in order: the editor window with crop and zoom, then annotation tools,
then measurement and colour, then scrolling capture, then OCR. See the roadmap
in the README.
