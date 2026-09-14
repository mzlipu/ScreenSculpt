// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSGeometry
import SSPlatform

/// Application entry point.
///
/// Deliberately thin: it owns the lifecycle and nothing else. Everything the
/// app can *do* is constructed in ``AppEnvironment``, which is the only place
/// in the codebase that news up a service.
@main
enum ScreenSculptMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment()
        self.environment = environment
        environment.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.stop()
    }

    /// The app lives in the menu bar, so closing the editor must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the dock icon with no window open reopens the editor rather
    /// than doing nothing.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { environment?.showEditor() }
        return true
    }
}
