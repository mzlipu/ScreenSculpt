// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSAnnotations
import SSImaging
import SSPersistence
import SSRecognition
import SSRecognitionUI

/// Text and barcode recognition, plus the blur-mode cycler that depends on it.
extension EditorWindowController {

    /// Copy the text in the marquee, or in the whole image when there is none.
    @objc public func recogniseText() {
        let source: RasterImage
        if let selection = store.document.selection,
           let cropped = store.raster.cropped(to: selection) {
            source = cropped
        } else {
            source = store.raster
        }

        do {
            let recognizer = TextRecognizer(
                languages: [settings[Settings.primaryOCRLanguage]],
                removeLineBreaks: settings[Settings.ocrRemoveLineBreaks]
            )
            let result = try recognizer.recognize(in: source)
            // Copied first either way; the window is for checking the read.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.plainText, forType: .string)

            let lines = result.plainText.split(separator: "\n").count
            onStatusMessage?(
                lines == 1 ? "Copied 1 line of text" : "Copied \(lines) lines of text"
            )
            if settings[Settings.showRecognisedText] { presentRecognised(result) }
        } catch {
            onStatusMessage?(error.localizedDescription)
        }
    }

    /// Show the result, reusing the window rather than stacking them up.
    private func presentRecognised(_ result: RecognizedText) {
        let controller = TextResultWindowController(
            result: result, removeLineBreaks: settings[Settings.ocrRemoveLineBreaks]
        )
        controller.onCopy = { [weak self] text in
            let lines = text.split(separator: "\n").count
            self?.onStatusMessage?(
                lines == 1 ? "Copied 1 line of text" : "Copied \(lines) lines of text"
            )
        }
        textResultWindow?.close()
        textResultWindow = controller
        controller.present()
    }

    /// Decode any QR or barcode in the image.
    @objc public func recogniseCodes() {
        let codes = BarcodeRecognizer.recognize(in: store.raster)
        guard let first = codes.first else {
            onStatusMessage?("No QR or barcode found")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(first.payload, forType: .string)
        onStatusMessage?(
            first.isBinary
                ? "Copied a binary \(first.symbology) payload as hex"
                : "Copied \(first.payload)"
        )
    }

    /// Cycle the selected blur through its modes.
    @objc public func cycleConcealMode() {
        guard let annotation = store.selectedAnnotation,
              case .conceal(var body) = annotation.body
        else {
            onStatusMessage?("Select a blur first")
            return
        }
        let modes = ConcealMode.allCases
        let next = modes[(modes.firstIndex(of: body.mode).map { $0 + 1 } ?? 0) % modes.count]
        body.mode = next
        var updated = annotation
        updated.body = .conceal(body)
        store.update(updated, name: "Change blur mode")
        refresh()
        onStatusMessage?(
            next.isIrreversible
                ? "\(next.label) — original pixels discarded"
                : "\(next.label) — partially reversible, prefer Pixelate for secrets"
        )
    }

}
