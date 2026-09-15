// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import Observation

/// Reads and writes preferences.
///
/// Observes `UserDefaults.didChangeNotification` so a `defaults write` from the
/// terminal is picked up live — the expert settings are a real interface, not a
/// hidden one, and they should not require a relaunch.
@Observable
@MainActor
public final class SettingsStore {

    @ObservationIgnored private let defaults: UserDefaults

    /// A Task rather than a block-based observer token: `deinit` is nonisolated
    /// and cannot touch a non-Sendable `NSObjectProtocol`, but cancelling a Task
    /// is always safe.
    @ObservationIgnored private var watcher: Task<Void, Never>?

    /// Bumped on every change, including external ones, so views refresh.
    public private(set) var revision = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watcher = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(
                named: UserDefaults.didChangeNotification
            )
            for await _ in changes {
                guard let self else { return }
                // Picks up `defaults write` from the terminal without a relaunch.
                self.revision += 1
            }
        }
    }

    deinit { watcher?.cancel() }

    public subscript<Value>(key: SettingKey<Value>) -> Value {
        get {
            _ = revision  // establish an observation dependency
            return key.decode(defaults.object(forKey: key.name)) ?? key.defaultValue
        }
        set {
            defaults.set(key.encode(newValue), forKey: key.name)
            revision += 1
        }
    }

    /// True when the user has explicitly set this key, as opposed to inheriting
    /// the default. Lets the settings window show "Default" honestly.
    public func isCustomised<Value>(_ key: SettingKey<Value>) -> Bool {
        defaults.object(forKey: key.name) != nil
    }

    public func reset<Value>(_ key: SettingKey<Value>) {
        defaults.removeObject(forKey: key.name)
        revision += 1
    }

    /// Restore every documented setting to its default.
    ///
    /// Deliberately does not touch permission bookkeeping or the Keychain:
    /// "reset my preferences" should not silently revoke a grant or discard
    /// credentials the user would then have to find again.
    public func resetAll() {
        let preserved = ["permissions.screenRecording.didPrompt",
                         "permissions.screenRecording.grantedForBuild"]
        guard let domain = defaults.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? ""
        ) else { return }
        for key in domain.keys where !preserved.contains(key) {
            defaults.removeObject(forKey: key)
        }
        revision += 1
    }

    // MARK: - Derived

    /// The folder screenshots are written to, creating it if needed.
    ///
    /// Falls back to ~/Pictures/Screenshots when the user has not chosen one, or
    /// when a previously chosen folder can no longer be resolved — a bookmark to
    /// a deleted or unmounted folder should degrade, not throw.
    public var screenshotFolder: URL {
        if let chosen = self[Settings.screenshotFolder] {
            return chosen
        }
        let pictures = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first
        return pictures?.appendingPathComponent("Screenshots", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
