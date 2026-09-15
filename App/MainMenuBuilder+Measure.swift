// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSEditorUI

extension MainMenuBuilder {

    static func measureMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Measure")
        menu.addItem(responder(
            "Copy Pixel Colour", #selector(EditorWindowController.copyPixelColor), "\t", []
        ))
        menu.addItem(responder(
            "Copy Text Colour", #selector(EditorWindowController.copyTextColor),
            "\t", [.shift]
        ))
        menu.addItem(responder(
            "Copy Average Colour", #selector(EditorWindowController.copyAverageColor), "c", []
        ))
        menu.addItem(.separator())
        menu.addItem(responder(
            "Auto-fit Selection", #selector(EditorWindowController.autoFitSelection), "a",
            [.command, .shift]
        ))
        menu.addItem(responder(
            "Show Sizes in Points", #selector(EditorWindowController.toggleLogicalPoints),
            "p", []
        ))
        menu.addItem(.separator())
        menu.addItem(responder(
            "Add Colour to Contrast Check",
            #selector(EditorWindowController.compareContrast), "x", []
        ))
        menu.addItem(responder(
            "Clear Contrast Check", #selector(EditorWindowController.clearContrast), ""
        ))
        menu.addItem(.separator())
        menu.addItem(responder(
            "Recognise Text", #selector(EditorWindowController.recogniseText), "o",
            [.command, .shift]
        ))
        menu.addItem(responder(
            "Recognise QR or Barcode", #selector(EditorWindowController.recogniseCodes), ""
        ))
        menu.addItem(responder(
            "Cycle Blur Mode", #selector(EditorWindowController.cycleConcealMode), "m", []
        ))
        return wrap(menu, title: "Measure")
    }

}
