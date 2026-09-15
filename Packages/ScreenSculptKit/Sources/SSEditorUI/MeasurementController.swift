// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSDocument
import SSGeometry
import SSImaging
import SSMeasure
import Observation

/// Colour readout and ruler state for one editor window.
///
/// Owns the decoded `PixelBuffer`, which is rebuilt only when the raster
/// actually changes — decoding is the expensive part, and every measurement
/// afterwards is a array walk that completes between mouse-moves.
@Observable
@MainActor
final class MeasurementController {

    /// Colour under the cursor, updated on every move.
    private(set) var hoverColor: RGBA8?
    private(set) var hoverPoint: ImagePoint?

    /// The most recent ruler measurement, if the user is holding an arrow key.
    private(set) var reading: RulerReading?

    /// Two colours picked for comparison, and their contrast.
    private(set) var comparison: (foreground: RGBA8, background: RGBA8)?

    /// Report sizes in logical points rather than device pixels.
    ///
    /// A display toggle only: the stored measurement never changes, which a
    /// test pins.
    var showLogicalPoints = false

    var format: ColorFormat = .hex

    @ObservationIgnored private var buffer: PixelBuffer?
    @ObservationIgnored private var bufferRevision = -1
    @ObservationIgnored private let store: DocumentStore

    init(store: DocumentStore) {
        self.store = store
    }

    /// Decode lazily, and only when the pixels have actually changed.
    private var pixels: PixelBuffer? {
        if bufferRevision != store.revision || buffer == nil {
            buffer = PixelBuffer(store.raster)
            bufferRevision = store.revision
        }
        return buffer
    }

    var isAvailable: Bool { !store.document.measurementUnavailable }

    // MARK: - Hover

    func updateHover(at point: ImagePoint) {
        hoverPoint = point
        hoverColor = pixels?.color(at: point)
    }

    func clearHover() {
        hoverPoint = nil
        hoverColor = nil
    }

    // MARK: - Picking

    /// Colour of the exact pixel under the cursor.
    func pickPixelColor() -> String? {
        guard let colour = hoverColor else { return nil }
        return copy(colour)
    }

    /// Colour of text under the cursor — the dark stroke, not its antialiased
    /// fringe.
    func pickTextColor() -> String? {
        guard let pixels, let point = hoverPoint,
              let colour = ColorSampler.textColor(in: pixels, around: point)
        else { return nil }
        return copy(colour)
    }

    /// Mean colour of the marquee, averaged in linear space.
    func pickAverageColor() -> String? {
        guard let pixels, let rect = store.document.selection,
              let colour = ColorSampler.averageColor(in: pixels, rect: rect)
        else { return nil }
        return copy(colour)
    }

    private func copy(_ colour: RGBA8) -> String {
        let text = ColorFormatter.string(for: colour, as: format)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    // MARK: - Contrast

    /// Take the hovered colour as foreground, then background, then report.
    func captureForComparison() -> String? {
        guard let colour = hoverColor else { return nil }
        if let existing = comparison {
            comparison = (foreground: existing.background, background: colour)
        } else {
            comparison = (foreground: colour, background: colour)
        }
        return contrastSummary
    }

    func clearComparison() { comparison = nil }

    /// Both standards, because they disagree and each audience wants one.
    var contrastSummary: String? {
        guard let comparison else { return nil }
        let ratio = Contrast.wcag2(
            foreground: comparison.foreground, background: comparison.background
        )
        let lc = Contrast.apca(
            text: comparison.foreground, background: comparison.background
        )
        let level = Contrast.wcagLevel(ratio)
        return String(
            format: "WCAG %.2f:1 %@   ·   APCA Lc %.0f — %@",
            ratio, level.rawValue, lc, Contrast.apcaVerdict(lc)
        )
    }

    // MARK: - Ruler

    /// Measure from the cursor along one axis.
    func measure(axis: Axis) {
        guard isAvailable, let pixels, let point = hoverPoint else { return }
        reading = RulerEngine.measure(from: point, axis: axis, in: pixels)
    }

    func clearReading() { reading = nil }

    /// Snap the marquee out to the edges of whatever it covers.
    func autoFitSelection() {
        guard let pixels, let rect = store.document.selection else { return }
        store.setSelection(ElementFitter.fit(rect, in: pixels))
    }

    // MARK: - Display

    /// Format a length for display, honouring the points/pixels toggle.
    func describe(_ length: ImagePx) -> String {
        guard showLogicalPoints else { return "\(Int(length.value.rounded())) px" }
        let points = length.inPoints(store.pixelScale)
        let rounded = (points.value * 10).rounded() / 10
        let text = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(rounded)
        return "\(text) pt"
    }

    var readingSummary: String? {
        guard let reading else { return nil }
        let axis = reading.axis == .horizontal ? "width" : "height"
        return "\(describe(reading.length))  \(axis)"
    }

    var hoverSummary: String? {
        guard let colour = hoverColor, let point = hoverPoint else { return nil }
        let position = showLogicalPoints
            ? "\(describe(point.x.magnitude)), \(describe(point.y.magnitude))"
            : "\(Int(point.x.value)), \(Int(point.y.value))"
        return "\(ColorFormatter.string(for: colour, as: format))   ·   \(position)"
    }
}
