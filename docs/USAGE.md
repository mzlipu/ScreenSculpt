# Using ScreenSculpt

> **v0.1.0 — early.** Capture, save and copy work. The editor, annotation tools,
> measurement, OCR and scrolling capture do not exist yet; the menu items for
> them are visible but greyed out so you can see where they will go.

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

Every capture is **saved to `~/Pictures/Screenshots` and copied to the
clipboard**, so you can paste it straight into Slack or a document.

The menu bar icon flashes and briefly shows the filename to confirm. Choosing
**Open Screenshots Folder** afterwards reveals the most recent one in Finder.

### While selecting an area

- **Drag** to select. The size is shown in both points and pixels.
- **Shift-drag** constrains to a square.
- A **magnifier** follows the cursor at 8×, with the exact pixel outlined in
  red, so you can land on a boundary precisely.
- **Escape** or **right-click** cancels.

The screen is frozen while you select, so animations, hover states and video
cannot move under your marquee.

### Shortcuts are not global yet

`⌃⇧⌘4` currently only works when ScreenSculpt is the frontmost app. Global
hotkeys that fire from anywhere need the `SSHotKeys` module, which is built but
not wired up. **Use the menu bar icon for now** — that always works.

These deliberately avoid `⇧⌘3` / `⇧⌘4`, which macOS reserves for its own
screenshot tool.

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

**The permission disappears after every update.** This used to happen and is now
fixed. Ad-hoc signing gave a designated requirement of `cdhash H"..."`, which
changes with every build, so macOS quietly stopped honouring the grant while
still showing a ticked box. Builds are now signed with a self-signed certificate,
which gives a stable `identifier + certificate` requirement instead. Run
`make cert` once; `make dmg` picks it up automatically.

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
