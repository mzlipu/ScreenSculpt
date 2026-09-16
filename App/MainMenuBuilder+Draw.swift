// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSEditorUI

extension MainMenuBuilder {

    /// The drawing tools. The two still greyed out are canvas-level features
    /// rather than annotations, and are listed here because that is where
    /// someone would look for them.
    static func drawMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Draw")
        // Bare letters, no modifier — the convention in every drawing app.
        menu.addItem(responder("Select", #selector(EditorWindowController.toolSelect), "v", []))
        menu.addItem(.separator())
        menu.addItem(responder("Arrow", #selector(EditorWindowController.toolArrow), "a", []))
        menu.addItem(responder("Line", #selector(EditorWindowController.toolLine), "l", []))
        menu.addItem(responder(
            "Rectangle", #selector(EditorWindowController.toolRectangle), "r", []
        ))
        menu.addItem(responder("Oval", #selector(EditorWindowController.toolOval), "o", []))
        menu.addItem(responder("Text", #selector(EditorWindowController.toolText), "t", []))
        menu.addItem(responder(
            "Freehand", #selector(EditorWindowController.toolFreehand), "d", []
        ))
        menu.addItem(responder(
            "Highlighter", #selector(EditorWindowController.toolHighlighter), "h", []
        ))
        menu.addItem(responder(
            "Blur / Conceal", #selector(EditorWindowController.toolConceal), "b", []
        ))
        menu.addItem(responder(
            "Counter", #selector(EditorWindowController.toolCounter), "n", []
        ))
        menu.addItem(.separator())
        menu.addItem(responder(
            "Duplicate", #selector(EditorWindowController.duplicateAnnotation), "d"
        ))
        menu.addItem(responder(
            "Delete Annotation", #selector(EditorWindowController.deleteAnnotation), "\u{8}", []
        ))
        menu.addItem(responder(
            "Flatten Annotations", #selector(EditorWindowController.flattenAnnotations), "e"
        ))
        menu.addItem(.separator())
        menu.addItem(responder(
            "Spotlight", #selector(EditorWindowController.toolSpotlight), "s", []
        ))
        menu.addItem(responder(
            "Magnifier", #selector(EditorWindowController.toolMagnifier), "m", []
        ))
        menu.addItem(responder("Ruler", #selector(EditorWindowController.toolRuler), "u", []))
        menu.addItem(responder(
            "Place Image…", #selector(EditorWindowController.placeImageFromFile), "i", []
        ))
        menu.addItem(responder(
            "Place Image from Clipboard",
            #selector(EditorWindowController.placeImageFromClipboard), "I", [.shift]
        ))
        menu.addItem(.separator())
        menu.addItem(stub("Backdrop"))
        menu.addItem(stub("Add Capture"))
        menu.addItem(.separator())
        menu.addItem(stub("Snap to Objects"))
        menu.addItem(stub("Snap to Similar Objects"))
        return wrap(menu, title: "Draw")
    }
}
