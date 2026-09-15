// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSImaging
import Testing

@testable import SSDocument

private func makeImage(
    width: Int = 400, height: Int = 300, scale: PixelScale = .x2
) -> RasterImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return RasterImage(cgImage: context.makeImage()!, pixelScale: scale)
}

@Suite("Raster operations")
@MainActor
struct RasterOpTests {

    @Test("Cropping changes the rendered size but never the original")
    func cropPreservesOrigin() {
        let store = DocumentStore(image: makeImage())
        store.crop(to: ImageRect(x: 10, y: 20, width: 100, height: 80))

        #expect(store.size == ImageSize(width: 100, height: 80))
        // The capture itself must survive, or Reset Crop could not work.
        #expect(store.document.origin.size == ImageSize(width: 400, height: 300))
    }

    @Test("Operations compose in order")
    func opsCompose() {
        let store = DocumentStore(image: makeImage())
        store.crop(to: ImageRect(x: 0, y: 0, width: 200, height: 200))
        store.resize(to: ImageSize(width: 50, height: 50))
        #expect(store.size == ImageSize(width: 50, height: 50))
    }

    @Test("Reset Crop restores the full image but keeps later operations")
    func resetCrop() {
        let store = DocumentStore(image: makeImage())
        store.crop(to: ImageRect(x: 10, y: 10, width: 100, height: 100))
        store.resetCrop()
        #expect(store.size == ImageSize(width: 400, height: 300))
        #expect(!store.document.isCropped)
    }

    @Test("A crop matching the whole image is not recorded")
    func noOpCropIgnored() {
        // Otherwise Enter with a full-image marquee would add a pointless undo
        // step the user then has to press Cmd-Z twice to escape.
        let store = DocumentStore(image: makeImage())
        store.crop(to: ImageRect(x: 0, y: 0, width: 400, height: 300))
        #expect(!store.canUndo)
    }

    @Test("Crops are clamped to the image")
    func cropClamped() {
        let store = DocumentStore(image: makeImage())
        store.crop(to: ImageRect(x: 350, y: 250, width: 500, height: 500))
        #expect(store.size == ImageSize(width: 50, height: 50))
    }

    @Test("Downscaling a 2x capture halves it and drops the retina flag")
    func downscale() {
        let store = DocumentStore(image: makeImage(scale: .x2))
        store.downscaleToOneX()
        #expect(store.size == ImageSize(width: 200, height: 150))
        #expect(store.pixelScale == .x1)
    }
}

@Suite("Undo")
@MainActor
struct UndoTests {

    @Test("Undo and redo walk the operation history")
    func undoRedo() {
        let store = DocumentStore(image: makeImage())
        store.crop(to: ImageRect(x: 0, y: 0, width: 200, height: 150))
        #expect(store.size == ImageSize(width: 200, height: 150))

        store.undo()
        #expect(store.size == ImageSize(width: 400, height: 300))

        store.redo()
        #expect(store.size == ImageSize(width: 200, height: 150))
    }

    @Test("Undo is available only when there is something to undo")
    func availability() {
        let store = DocumentStore(image: makeImage())
        #expect(!store.canUndo)
        #expect(!store.canRedo)

        store.crop(to: ImageRect(x: 0, y: 0, width: 100, height: 100))
        #expect(store.canUndo)
        #expect(!store.canRedo)

        store.undo()
        #expect(!store.canUndo)
        #expect(store.canRedo)
    }

    @Test("A new edit discards the redo branch")
    func newEditClearsRedo() {
        let store = DocumentStore(image: makeImage())
        store.crop(to: ImageRect(x: 0, y: 0, width: 200, height: 200))
        store.undo()
        #expect(store.canRedo)

        store.crop(to: ImageRect(x: 0, y: 0, width: 120, height: 120))
        #expect(!store.canRedo)
    }

    @Test("Undo survives many steps and reaches the original")
    func deepHistory() {
        let store = DocumentStore(image: makeImage(width: 1000, height: 1000))
        for i in 1...10 {
            store.crop(to: ImageRect(
                x: .zero, y: .zero,
                width: ImagePx(1000 - i * 50), height: ImagePx(1000 - i * 50)
            ))
        }
        for _ in 1...10 { store.undo() }
        #expect(store.size == ImageSize(width: 1000, height: 1000))
        #expect(!store.canUndo)
    }

    @Test("Undoing a crop does not resurrect a stale selection")
    func undoClearsSelection() {
        // Selection is transient UI state, deliberately outside history.
        let store = DocumentStore(image: makeImage())
        store.setSelection(ImageRect(x: 10, y: 10, width: 50, height: 50))
        store.cropToSelection()
        store.undo()
        #expect(store.document.selection == nil)
    }
}

@Suite("Selection")
@MainActor
struct SelectionTests {

    @Test("An empty selection is stored as none")
    func emptySelectionIsNil() {
        let store = DocumentStore(image: makeImage())
        store.setSelection(ImageRect(x: 10, y: 10, width: 0, height: 0))
        #expect(store.document.selection == nil)
    }

    @Test("Crop to selection uses the marquee")
    func cropToSelection() {
        let store = DocumentStore(image: makeImage())
        store.setSelection(ImageRect(x: 20, y: 30, width: 120, height: 90))
        store.cropToSelection()
        #expect(store.size == ImageSize(width: 120, height: 90))
        #expect(store.document.selection == nil)
    }

    @Test("Crop to selection with no marquee does nothing")
    func cropWithoutSelection() {
        let store = DocumentStore(image: makeImage())
        store.cropToSelection()
        #expect(store.size == ImageSize(width: 400, height: 300))
        #expect(!store.canUndo)
    }
}
