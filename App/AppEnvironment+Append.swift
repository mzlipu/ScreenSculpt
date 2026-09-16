// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSEditorUI

/// Servicing the editor's request for another capture.
///
/// The editor owns the document but not the capture UI, so it asks rather than
/// reaching across for it — which is what keeps SSEditorUI independent of
/// SSCaptureUI.
extension AppEnvironment {

    func wireAppendRequest(on controller: EditorWindowController) {
        controller.onRequestAppend = { [weak self, weak controller] in
            guard let self, let controller else { return }
            Task { @MainActor in
                guard let selection = try? await self.areaSelection.selectRegion() else { return }
                controller.append(selection.image)
            }
        }
    }
}
