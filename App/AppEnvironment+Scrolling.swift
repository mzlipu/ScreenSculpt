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

            guard let selection = try? await areaSelection.selectRegion() else { return }
            let region = selection.rect

            guard ensureAccessibility() else { return }

            let controller = ScrollingCaptureController(captureService: captureService)
            let panel = ScrollProgressPanel(region: region)
            panel.show()

            do {
                let result = try await controller.capture(area: region) { progress in
                    panel.update(frames: progress.frames, rows: progress.rows)
                }
                panel.close()
                deliverScroll(result, controller: controller)
            } catch {
                panel.close()
                presentScrollFailure(error)
            }
        }
    }

    /// Ask for Accessibility, explaining what it is for first.
    private func ensureAccessibility() -> Bool {
        if permissions.refreshAccessibility() == .granted { return true }

        let alert = NSAlert()
        alert.messageText = "Let ScreenSculpt scroll for you"
        alert.informativeText = """
            To capture a page taller than the screen, ScreenSculpt scrolls the \
            window a little at a time and joins the frames together. macOS calls \
            that Accessibility access.

            It is used only while a scrolling capture is running, and only to \
            send scroll input to the window you picked.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        _ = permissions.requestAccessibility()
        permissions.openSettings(for: .accessibility)
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

/// A small floating panel showing how the capture is going.
///
/// Deliberately placed outside the captured region — anything overlapping it
/// would be photographed into the result.
@MainActor
final class ScrollProgressPanel {

    private let panel: NSPanel
    private let label: NSTextField

    init(region: ScreenRect) {
        label = NSTextField(labelWithString: "Starting…")
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 56),
            styleMask: [.titled, .utilityWindow, .hudWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Scrolling capture"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.contentView?.addSubview(label)
        label.frame = NSRect(x: 12, y: 14, width: 236, height: 22)

        position(avoiding: region)
    }

    /// Keep clear of the region being captured.
    private func position(avoiding region: ScreenRect) {
        guard let screen = NSScreen.main else { panel.center(); return }
        let visible = screen.visibleFrame
        let cocoa = CocoaBridge.toCocoa(region, topology: CocoaBridge.currentTopology())
        let below = cocoa.maxY + 20 > visible.maxY - 80

        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - 130,
                y: below ? visible.minY + 24 : visible.maxY - 90
            )
        )
    }

    func show() { panel.orderFrontRegardless() }

    func update(frames: Int, rows: Int) {
        label.stringValue = "\(frames) frames · \(rows) px"
    }

    func close() { panel.orderOut(nil) }
}
