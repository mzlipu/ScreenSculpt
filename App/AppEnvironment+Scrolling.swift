// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSCapture
import SSExport
import SSGeometry
import SSImaging
import SSPersistence
import SSPlatform
import SSStitch

extension AppEnvironment {

    /// Capture a scrolling region: pick an area, then let the app scroll it.
    ///
    /// Accessibility is requested here and nowhere else. Asking at launch for a
    /// permission most sessions never use trains people to grant things without
    /// reading them; asking at the moment they press "capture a long page" makes
    /// the reason self-evident.
    @objc func captureScrolling() {
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            defer { isCapturing = false }
            guard await PermissionPresenter.ensureScreenRecording(permissions) else { return }

            // Decide how the page will be scrolled before asking for a region.
            // Checking afterwards meant dragging out a selection, being sent to
            // System Settings, and returning to find the selection gone.
            guard let mode = await chooseScrollMode() else { return }

            guard let selection = try? await areaSelection.selectRegion() else { return }
            let region = selection.rect

            let controller = ScrollingCaptureController(captureService: captureService)
            let panel = StatusPanel(
                title: mode == .manual ? "Scroll the page yourself" : "Scrolling capture",
                region: region
            )
            if mode == .manual {
                panel.update("Scroll the window · click Done when finished")
                panel.setPrimaryButton("Done")
            }
            panel.show()

            do {
                let result: StitchResult = switch mode {
                case .automatic:
                    try await controller.capture(area: region) { progress in
                        panel.update("\(progress.frames) frames · \(progress.rows) px")
                    }
                case .manual:
                    try await controller.captureManually(area: region) {
                        panel.wasCancelled
                    } onProgress: { progress in
                        panel.update("\(progress.frames) frames · \(progress.rows) px")
                    }
                }
                panel.close()
                deliverScroll(result, controller: controller)
            } catch {
                panel.close()
                presentScrollFailure(error)
            }
        }
    }

    enum ScrollMode { case automatic, manual }

    /// Pick between letting the app scroll and scrolling by hand.
    ///
    /// Manual is offered as an equal, not as a consolation: it needs no
    /// permission at all, works in applications that ignore synthesised input,
    /// and scrolls sideways as happily as down. Someone who would rather not
    /// hand a screenshot tool the ability to send input should not thereby lose
    /// the feature.
    private func chooseScrollMode() async -> ScrollMode? {
        if permissions.refreshAccessibility() == .granted { return .automatic }

        let alert = NSAlert()
        alert.messageText = "How should the page be scrolled?"
        alert.informativeText = """
            ScreenSculpt captures a page taller than the screen by joining \
            frames together as the page scrolls.

            It can scroll the window for you, which macOS calls Accessibility \
            access — used only while a capture is running, and only on the \
            window you pick. Or you can scroll yourself and it will watch, \
            which needs no permission.
            """
        alert.addButton(withTitle: "I'll Scroll It Myself")
        alert.addButton(withTitle: "Let Screen Sculpt Scroll")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .manual
        case .alertSecondButtonReturn:
            guard confirmSingleInstallation() else { return nil }
            // Registers the app in the Accessibility list, so there is
            // something to switch on rather than a + button and a file picker.
            _ = permissions.requestAccessibility()
            permissions.openSettings(for: .accessibility)
            return await waitForAccessibility() ? .automatic : nil
        default:
            return nil
        }
    }

    /// Warn when more than one copy exists, before the grant is attempted.
    ///
    /// macOS records a permission against one *copy* of an application, so a
    /// second bundle sharing the identifier gets a separate entry — and the
    /// Privacy list shows both as plain "Screen Sculpt" with no path to tell
    /// them apart. Switching on the wrong one is indistinguishable from
    /// switching on the right one and being ignored, which is a very long way
    /// to chase a problem that a sentence here prevents.
    private func confirmSingleInstallation() -> Bool {
        let copies = permissions.duplicateInstallations()
        guard copies.count > 1 else { return true }

        let alert = NSAlert()
        alert.messageText = "There is more than one copy of Screen Sculpt"
        alert.informativeText = """
            macOS grants permission to a particular copy of an app, and the \
            Accessibility list shows every copy under the same name. Granting \
            it to the wrong one looks like it worked and does nothing.

            Copies found:
            \(copies.map { "  • \($0.path)" }.joined(separator: "\n"))

            Keep the one in /Applications and delete the rest, then try again.
            """
        alert.addButton(withTitle: "Show Me")
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting(copies)
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Poll until the grant appears, then carry on.
    ///
    /// The grant is made in another process, so the app cannot be told when it
    /// happens — it has to look. Aborting and asking the user to start over is
    /// the common shape here and a poor one: they have just done what was
    /// asked, and the reward is to repeat themselves.
    private func waitForAccessibility() async -> Bool {
        let panel = StatusPanel(title: "Waiting for permission", region: nil)
        panel.update("Turn on Screen Sculpt in System Settings…")
        panel.show()

        let deadline = ContinuousClock.now + .seconds(180)
        var elapsed = 0
        while ContinuousClock.now < deadline, !panel.wasCancelled {
            if permissions.refreshAccessibility() == .granted {
                panel.close()
                return true
            }
            try? await Task.sleep(for: .milliseconds(400))
            elapsed += 400
            if elapsed == 20_000 {
                panel.update("Still waiting — a relaunch may be needed.")
            }
        }
        panel.close()
        guard !panel.wasCancelled else { return false }

        // A grant that is visibly on but not in effect means the process must
        // start again to pick it up.
        // A switch that is visibly on while the app is still refused means the
        // entry was recorded against a different build or a different copy.
        // Toggling it off and on keeps the stale record; removing the row
        // discards it, and the next request writes a fresh one.
        let retry = NSAlert()
        retry.messageText = "Screen Sculpt still does not have Accessibility access"
        retry.informativeText = """
            If the switch is already on, the entry belongs to an older build \
            and no longer matches this one. Turning it off and on again keeps \
            that stale entry.

            Select ScreenSculpt in the Accessibility list, remove it with the \
            minus button, then add this copy back:
            \(Bundle.main.bundleURL.path)

            Or reset it from Terminal and try again:
            \(permissions.resetCommand(for: .accessibility))
            """
        retry.addButton(withTitle: "Open System Settings")
        retry.addButton(withTitle: "Relaunch")
        retry.addButton(withTitle: "Cancel")

        switch retry.runModal() {
        case .alertFirstButtonReturn: permissions.openSettings(for: .accessibility)
        case .alertSecondButtonReturn: permissions.relaunch()
        default: break
        }
        return false
    }

    // MARK: - Results

    private func deliverScroll(_ result: StitchResult, controller: ScrollingCaptureController) {
        guard !result.isEmpty else {
            announce("Nothing captured", body: "The page did not scroll.")
            return
        }
        for warning in result.warnings { NSLog("[ScreenSculpt] stitch: %@", warning) }

        let summary = "\(result.frameCount) frames · \(result.rows)px tall"
        guard let image = controller.finishedImage() else {
            // Too tall to hold as a single image, so it goes straight to disk
            // through the streaming encoder. JPEG cannot represent it either —
            // the format's height field stops at 65,535.
            guard let url = writeLongCapture(controller) else {
                announce("Could not save", body: "The capture was too large to write.")
                return
            }
            announce("Saved long capture", body: summary, revealing: url)
            return
        }

        openEditor(
            for: CaptureResult(
                image: image,
                provenance: CaptureProvenance(
                    sourceRect: nil, pixelScale: image.pixelScale,
                    displays: [], sourceDisplayID: nil, spansMixedScales: false
                )
            )
        )
        if !result.warnings.isEmpty {
            announce("Captured with warnings", body: result.warnings[0])
        }
    }

    private func writeLongCapture(_ controller: ScrollingCaptureController) -> URL? {
        let name = Exporter.filename(
            for: .png, template: settings[Settings.filenameTemplate]
        )
        let url = settings.screenshotFolder.appendingPathComponent(name)
        do {
            try controller.writePNG(to: url)
            return url
        } catch {
            NSLog("[ScreenSculpt] long capture failed: %@", error.localizedDescription)
            return nil
        }
    }

    private func presentScrollFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "The scrolling capture stopped"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// A small floating panel for work that takes a while.
///
/// Positioned clear of the region being captured — anything overlapping it
/// would be photographed into the result.
@MainActor
final class StatusPanel {

    private let panel: NSPanel
    private let label: NSTextField
    private var button: NSButton!
    private(set) var wasCancelled = false

    init(title: String, region: ScreenRect?) {
        label = NSTextField(labelWithString: "Starting…")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 88),
            // Non-activating: in manual mode the user has to keep scrolling the
            // window behind this, and a panel that steals focus would put the
            // scroll somewhere else.
            styleMask: [.titled, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.contentView?.addSubview(label)
        label.frame = NSRect(x: 12, y: 50, width: 276, height: 22)

        button = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 110, y: 12, width: 80, height: 28)
        panel.contentView?.addSubview(button)

        position(avoiding: region)
    }

    @objc private func cancel() { wasCancelled = true }

    /// In manual mode the button ends the capture rather than abandoning it, so
    /// it should not say Cancel.
    func setPrimaryButton(_ title: String) {
        button.title = title
        button.keyEquivalent = "\r"
    }

    private func position(avoiding region: ScreenRect?) {
        guard let screen = NSScreen.main else { panel.center(); return }
        let visible = screen.visibleFrame
        var below = false
        if let region {
            let cocoa = CocoaBridge.toCocoa(region, topology: CocoaBridge.currentTopology())
            below = cocoa.maxY + 20 > visible.maxY - 110
        }
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - 150,
                y: below ? visible.minY + 24 : visible.maxY - 120
            )
        )
    }

    func show() { panel.orderFrontRegardless() }

    func update(_ text: String) { label.stringValue = text }

    func close() { panel.orderOut(nil) }
}
