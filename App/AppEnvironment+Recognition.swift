// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSPersistence
import SSRecognition
import SSRecognitionUI

/// Presenting what recognition read.
extension AppEnvironment {

    /// Put a recognition result on screen.
    ///
    /// One window, reused: recognising repeatedly is normal, and a new window
    /// per attempt would bury the screen.
    func showRecognisedText(_ result: RecognizedText) {
        let controller = TextResultWindowController(
            result: result, removeLineBreaks: settings[Settings.ocrRemoveLineBreaks]
        )
        controller.onCopy = { [weak self] text in
            let lines = text.split(separator: "\n").count
            self?.announce("Copied", body: lines == 1 ? "1 line" : "\(lines) lines")
        }
        textResultWindow?.close()
        textResultWindow = controller
        updateDockPresence()
        controller.present()
    }
}
