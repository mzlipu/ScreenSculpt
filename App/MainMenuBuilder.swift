// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSEditorUI

/// Builds the main menu bar in code.
///
/// No `MainMenu.nib`. A nib is a binary blob that cannot be reviewed in a pull
/// request, and the menu is the surface where new commands appear most often —
/// keeping it as source means a new tool shows up as a readable diff.
///
/// Menu items are stubs until their subsystems land; each is disabled rather
/// than absent, so the shape of the finished app is visible from day one.
@MainActor
enum MainMenuBuilder {

    private static var target: AnyObject?

    static func install(target: AnyObject? = nil) {
        self.target = target
        let main = NSMenu()
        main.addItem(appMenuItem())
        main.addItem(captureMenuItem())
        main.addItem(fileMenuItem())
        main.addItem(editMenuItem())
        main.addItem(drawMenuItem())
        main.addItem(measureMenuItem())
        main.addItem(zoomMenuItem())
        main.addItem(windowMenuItem())
        main.addItem(helpMenuItem())
        NSApp.mainMenu = main
    }

    // MARK: - Menus

    private static func appMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "About ScreenSculpt",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(live(
            "Settings…", #selector(AppEnvironment.showSettings), ",", [.command]
        ))
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide ScreenSculpt",
            action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit ScreenSculpt",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        return wrap(menu, title: "ScreenSculpt")
    }

    private static func captureMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Capture")
        menu.addItem(live("Capture Area…", #selector(AppEnvironment.captureArea), "4",
                          [.command, .shift, .control]))
        menu.addItem(live("Capture Fullscreen", #selector(AppEnvironment.captureFullscreen), "3",
                          [.command, .shift, .control]))
        menu.addItem(live(
            "Capture Active Window", #selector(AppEnvironment.captureActiveWindow), "5",
            [.command, .shift, .control]
        ))
        return wrap(menu, title: "Capture")
    }

    private static func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(responder("Copy Image", #selector(EditorWindowController.copyImage), "c"))
        menu.addItem(responder("Save Image", #selector(EditorWindowController.saveImage), "s"))
        menu.addItem(stub("Save Image As…", key: "S", modifiers: [.command, .shift]))
        menu.addItem(stub("Upload Image", key: "e"))
        menu.addItem(stub("Pin to Screen", key: "p"))
        menu.addItem(stub("Print…", key: "P", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(stub("Open File…", key: "O", modifiers: [.command, .shift]))
        menu.addItem(stub("Open From Clipboard", key: "V", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        return wrap(menu, title: "File")
    }

    private static func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(responder("Undo", #selector(EditorWindowController.undo), "z"))
        menu.addItem(responder(
            "Redo", #selector(EditorWindowController.redo), "Z", [.command, .shift]
        ))
        menu.addItem(.separator())
        menu.addItem(responder(
            "Crop to Selection", #selector(EditorWindowController.cropToSelection), "k"
        ))
        menu.addItem(responder("Reset Crop", #selector(EditorWindowController.resetCrop), ""))
        // Flatten is one more RasterOp, so unlike most implementations of this
        // command it is undoable.
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"
        )
        menu.addItem(
            withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        )
        menu.addItem(
            withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        return wrap(menu, title: "Edit")
    }

    /// The sixteen tools. Nine ship in Phase 1; the rest are visible and
    /// disabled so the intended shape of the app is legible.
    private static func drawMenuItem() -> NSMenuItem {
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
        menu.addItem(stub("Spotlight"))
        menu.addItem(stub("Magnifier"))
        menu.addItem(stub("Ruler"))
        menu.addItem(stub("Image Overlay"))
        menu.addItem(stub("Backdrop"))
        menu.addItem(stub("Add Capture"))
        menu.addItem(.separator())
        menu.addItem(stub("Snap to Objects"))
        menu.addItem(stub("Snap to Similar Objects"))
        return wrap(menu, title: "Draw")
    }

    /// Colour and ruler commands.
    ///
    /// Bare letters with no modifier, because these are used with the pointer
    /// parked over a pixel and a chord means moving a hand off the mouse.
    private static func zoomMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Zoom")
        menu.addItem(responder("Zoom In", #selector(EditorWindowController.zoomIn), "+"))
        menu.addItem(responder("Zoom Out", #selector(EditorWindowController.zoomOut), "-"))
        menu.addItem(responder("Zoom to Fit", #selector(EditorWindowController.zoomToFit), "1"))
        menu.addItem(responder(
            "Actual Size (100%)", #selector(EditorWindowController.zoomToActualSize), "0"
        ))
        menu.addItem(responder(
            "Zoom to Selection", #selector(EditorWindowController.zoomToSelection), "2"
        ))
        menu.addItem(.separator())
        menu.addItem(stub("Selection Top Left", key: "q", modifiers: []))
        menu.addItem(stub("Selection Bottom Right", key: "w", modifiers: []))
        return wrap(menu, title: "Zoom")
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""
        )
        let item = wrap(menu, title: "Window")
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        menu.addItem(stub("ScreenSculpt Help"))
        menu.addItem(stub("Keyboard Shortcuts"))
        // Highest-traffic support page for an app in this category.
        menu.addItem(stub("Screen Recording Permission…"))
        menu.addItem(.separator())
        menu.addItem(stub("Release Notes"))
        let item = wrap(menu, title: "Help")
        NSApp.helpMenu = menu
        return item
    }

    // MARK: - Helpers

    static func wrap(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        menu.title = title
        return item
    }

    /// A menu item dispatched through the responder chain, so it targets
    /// whichever editor window is frontmost and is greyed out when none is.
    static func responder(
        _ title: String, _ action: Selector, _ key: String,
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = nil          // nil target = responder chain
        return item
    }

    /// A menu item wired to a real action on the composition root.
    private static func live(
        _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    /// A menu item whose subsystem has not landed yet. Disabled, not hidden.
    private static func stub(
        _ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.isEnabled = false
        return item
    }
}
