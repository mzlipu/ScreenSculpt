// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import Testing

@testable import SSPersistence

/// A private defaults domain per test, so tests cannot interfere with each
/// other or with the real application's preferences.
private struct Scratch {
    let store: SettingsStore
    let defaults: UserDefaults
    let suite: String

    @MainActor
    init() {
        suite = "ss-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = SettingsStore(defaults: defaults)
    }

    func cleanUp() { UserDefaults.standard.removePersistentDomain(forName: suite) }
}

@Suite("Settings storage")
@MainActor
struct SettingsStoreTests {

    @Test("An unset key reports its default")
    func defaults() {
        let scratch = Scratch(); defer { scratch.cleanUp() }
        let store = scratch.store

        #expect(store[Settings.saveFormat] == .auto)
        #expect(store[Settings.downscaleRetina] == false)
        #expect(store[Settings.scrollingMaxHeight] == 20_000)
        #expect(!store.isCustomised(Settings.saveFormat))
    }

    @Test("Values round-trip")
    func roundTrip() {
        let scratch = Scratch(); defer { scratch.cleanUp() }
        let store = scratch.store

        store[Settings.saveFormat] = .jpeg
        store[Settings.downscaleRetina] = true
        store[Settings.filenameTemplate] = "shot-%Y"
        store[Settings.jpegQuality] = 0.65

        #expect(store[Settings.saveFormat] == .jpeg)
        #expect(store[Settings.downscaleRetina])
        #expect(store[Settings.filenameTemplate] == "shot-%Y")
        #expect(abs(store[Settings.jpegQuality] - 0.65) < 1e-9)
        #expect(store.isCustomised(Settings.saveFormat))
    }

    @Test("Enums are stored as readable strings, so `defaults write` works")
    func enumsStoreAsStrings() {
        let scratch = Scratch(); defer { scratch.cleanUp() }
        let store = scratch.store
        let defaults = scratch.defaults

        store[Settings.afterCapture] = .copyOnly
        // The whole point of the string encoding: a user can set this from the
        // terminal and read it back without decoding an integer.
        #expect(defaults.string(forKey: "afterCapture") == "copyOnly")
    }

    @Test("An externally written value is picked up")
    func externalWrite() {
        let scratch = Scratch(); defer { scratch.cleanUp() }
        let store = scratch.store
        let defaults = scratch.defaults

        defaults.set("png", forKey: "saveFormat")
        #expect(store[Settings.saveFormat] == .png)
    }

    @Test("An unrecognised raw value falls back to the default rather than trapping")
    func garbageValue() {
        let scratch = Scratch(); defer { scratch.cleanUp() }
        let store = scratch.store
        let defaults = scratch.defaults

        // Someone will inevitably type `defaults write … saveFormat gif`.
        defaults.set("gif", forKey: "saveFormat")
        #expect(store[Settings.saveFormat] == .auto)
    }

    @Test("Resetting one key restores its default")
    func resetOne() {
        let scratch = Scratch(); defer { scratch.cleanUp() }
        let store = scratch.store

        store[Settings.downscaleRetina] = true
        store.reset(Settings.downscaleRetina)
        #expect(store[Settings.downscaleRetina] == false)
        #expect(!store.isCustomised(Settings.downscaleRetina))
    }

    @Test("The screenshots folder falls back when none is chosen")
    func folderFallback() {
        let scratch = Scratch(); defer { scratch.cleanUp() }
        let store = scratch.store

        #expect(store.screenshotFolder.lastPathComponent == "Screenshots")
    }
}

@Suite("After-capture behaviour")
struct AfterCaptureTests {

    @Test("Each mode reports the right combination of actions")
    func modes() {
        #expect(AfterCapture.editor.opensEditor)
        #expect(!AfterCapture.editor.copies)
        #expect(!AfterCapture.editor.saves)

        #expect(AfterCapture.copyAndSave.copies)
        #expect(AfterCapture.copyAndSave.saves)
        #expect(!AfterCapture.copyAndSave.opensEditor)

        #expect(AfterCapture.copyOnly.copies)
        #expect(!AfterCapture.copyOnly.saves)

        #expect(AfterCapture.saveOnly.saves)
        #expect(!AfterCapture.saveOnly.copies)
    }
}
