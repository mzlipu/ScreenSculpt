// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSAnnotations
import SSGeometry
import UniformTypeIdentifiers

/// Placing an image onto the canvas.
///
/// Unlike every other tool, an overlay cannot be drawn from a drag — the
/// content has to come from somewhere first. So it is placed by a command and
/// then moved and resized like anything else, rather than living on the tool
/// palette where it would do nothing when clicked.
extension EditorWindowController {

    @objc public func placeImageFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .heic, .bmp]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to place on the screenshot"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            onStatusMessage?("That file could not be read as an image")
            return
        }
        place(image, describedAs: url.lastPathComponent)
    }

    @objc public func placeImageFromClipboard() {
        guard
            let items = NSPasteboard.general.readObjects(forClasses: [NSImage.self]),
            let first = items.first as? NSImage,
            let image = first.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            onStatusMessage?("No image on the clipboard")
            return
        }
        place(image, describedAs: "the clipboard")
    }

    /// Insert at a sensible size, centred on the visible canvas.
    private func place(_ image: CGImage, describedAs source: String) {
        let canvas = store.raster.bounds
        // A third of the shorter side: large enough to see, small enough not to
        // bury the screenshot it is being placed on.
        let target = min(canvas.width.value, canvas.height.value) / 3
        let aspect = image.height == 0 ? 1 : Double(image.width) / Double(image.height)
        let width = aspect >= 1 ? target : target * aspect
        let height = aspect >= 1 ? target / aspect : target

        let rect = ImageRect(
            x: ImagePx(canvas.midX.value - width / 2),
            y: ImagePx(canvas.midY.value - height / 2),
            width: ImagePx(width), height: ImagePx(height)
        )

        guard let body = ImageOverlayBody.make(from: image, at: rect) else {
            onStatusMessage?(
                "That image is too large to embed — it would have to be under "
                    + "\(ImageOverlayBody.maximumBytes / 1_048_576) MB once encoded"
            )
            return
        }
        store.add(.imageOverlay(body), style: tools.style)
        refresh()
        onStatusMessage?("Placed the image from \(source)")
    }
}
