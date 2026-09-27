// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit

/// What Command-Q does.
///
/// Normally it quits. Here it closes the front window and leaves the app
/// running, because this app is not the window — it is the menu bar item and
/// the global capture shortcuts, and those are the whole point of it. Someone
/// who has just finished with a screenshot and reaches for Command-Q means
/// "put this away", not "disable my capture shortcuts until I notice and
/// relaunch". The old behaviour did the second thing silently.
///
/// Quitting is therefore deliberate only: the Quit item in the menu bar icon's
/// menu, or in the app menu when a window is open. Both still work on click.
/// Neither advertises a shortcut any more, because a menu that shows Command-Q
/// next to Quit and then does not quit is worse than one that shows nothing.
extension AppEnvironment {

    /// Intercept Command-Q before it reaches anything that would act on it.
    ///
    /// A local monitor rather than a menu item: the point is that no menu item
    /// owns this key, so the shortcut cannot be read off the interface as a
    /// promise to quit. Local monitors only see events routed to this app, so
    /// Command-Q still quits whatever is frontmost when Screen Sculpt is not.
    func installQuitShortcutPolicy() {
        guard quitShortcutMonitor == nil else { return }
        quitShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Bare Command only. Option-Command-Q and friends are left alone
            // rather than quietly absorbed.
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "q"
            else { return event }

            MainActor.assumeIsolated {
                // Closable only. The selection overlay is borderless, and
                // `performClose` on a window with no close box just beeps —
                // an unexplained noise in the middle of dragging out a
                // region. Escape already cancels that; here we do nothing.
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                      window.styleMask.contains(.closable)
                else { return }
                // `performClose` and not `close`: it runs the window's
                // delegate, which is what drops the Dock tile and forgets the
                // editor, so Command-Q and the close button end in the same
                // place.
                window.performClose(nil)
            }
            return nil
        }
    }

    func removeQuitShortcutPolicy() {
        if let quitShortcutMonitor { NSEvent.removeMonitor(quitShortcutMonitor) }
        quitShortcutMonitor = nil
    }
}
