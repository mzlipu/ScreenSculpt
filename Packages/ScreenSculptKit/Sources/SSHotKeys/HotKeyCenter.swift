// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CHotKeyShim
import Foundation
import Observation
import SSPersistence

/// Registers system-wide hotkeys and reports which one fired.
///
/// Built on Carbon's `RegisterEventHotKey`, reached through `CHotKeyShim`
/// because no macOS 26 SDK header declares it any more. That API is worth the
/// trouble: it is the only one that captures a hotkey system-wide **without
/// Accessibility permission**. The alternatives both need it — `CGEventTap`
/// also taxes every keystroke on the machine, and `NSEvent` global monitors
/// cannot consume the event, so the frontmost app sees it too.
@Observable
@MainActor
public final class HotKeyCenter {

    public enum RegistrationResult: Equatable, Sendable {
        case registered
        case alreadyTakenBySystem
        case rejectedInsufficientModifiers
        case failed(OSStatus)
    }

    /// Fired on the main actor when a registered hotkey is pressed.
    @ObservationIgnored public var onTrigger: ((HotKeyID) -> Void)?

    public private(set) var bindings: [HotKeyID: HotKeyBinding] = [:]
    public private(set) var lastError: String?

    @ObservationIgnored private var registered: [HotKeyID: SSEventHotKeyRef] = [:]
    @ObservationIgnored private var handler: SSEventHandlerRef?
    @ObservationIgnored private let settings: SettingsStore

    private static let storageKey = SettingKey("hotkeyBindings", default: "")

    /// Bumped when the shipped defaults change, so existing installs can be
    /// migrated without discarding anything the user chose themselves.
    private static let defaultsRevision = 3
    private static let revisionKey = SettingKey("hotkeyDefaultsRevision", default: 0)

    /// The live instance, so the C callback can find its way home.
    ///
    /// Carbon hands back a plain C function pointer with a void* context; a
    /// single main-actor instance is simpler and safer than juggling an
    /// Unmanaged box for an object that exists exactly once.
    @ObservationIgnored fileprivate static weak var shared: HotKeyCenter?

    public init(settings: SettingsStore) {
        self.settings = settings
        Self.shared = self
        loadBindings()
        installHandler()
        registerAll()
    }

    deinit {
        MainActor.assumeIsolated {
            for ref in registered.values { UnregisterEventHotKey(ref) }
            if let handler { RemoveEventHandler(handler) }
        }
    }

    // MARK: - Persistence

    private func loadBindings() {
        let raw = settings[Self.storageKey]
        if raw.isEmpty {
            bindings = Self.shippedDefaults()
            settings[Self.revisionKey] = Self.defaultsRevision
            return
        }
        let decoded = (try? JSONDecoder().decode(
            [String: HotKeyBinding].self, from: Data(raw.utf8)
        )) ?? [:]
        bindings = Dictionary(
            uniqueKeysWithValues: decoded.compactMap { key, value in
                HotKeyID(rawValue: key).map { ($0, value) }
            }
        )
        migrateDefaultsIfNeeded()
    }

    private static func shippedDefaults() -> [HotKeyID: HotKeyBinding] {
        Dictionary(
            uniqueKeysWithValues: HotKeyID.allCases.compactMap { id in
                id.defaultBinding.map { (id, $0) }
            }
        )
    }

    /// Move installs onto new shipped defaults **without** overwriting choices.
    ///
    /// A binding is only replaced when it still exactly matches the old shipped
    /// default — meaning the user never touched it. Anything they set
    /// deliberately survives, which is the difference between a migration and
    /// losing someone's configuration.
    private func migrateDefaultsIfNeeded() {
        guard settings[Self.revisionKey] < Self.defaultsRevision else { return }

        var changed = false
        for id in HotKeyID.allCases {
            guard let newDefault = id.defaultBinding else { continue }
            let current = bindings[id]
            let wasUntouched = current == nil
                || current == HotKeyID.legacyDefaultBinding(for: id)
            if wasUntouched, current != newDefault {
                bindings[id] = newDefault
                changed = true
            }
        }

        settings[Self.revisionKey] = Self.defaultsRevision
        if changed { saveBindings() }
    }

    private func saveBindings() {
        let encodable = Dictionary(
            uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) }
        )
        guard
            let data = try? JSONEncoder().encode(encodable),
            let text = String(bytes: data, encoding: .utf8)
        else { return }
        settings[Self.storageKey] = text
    }

    // MARK: - Registration

    private func installHandler() {
        var reference: SSEventHandlerRef?
        let status = ss_install_hotkey_handler({ _, event, _ in
            guard let event else { return noErr }
            var identifier: UInt32 = 0
            guard ss_hotkey_id_from_event(event, &identifier) == noErr else { return noErr }
            // The callback arrives on the main run loop, but Swift cannot know
            // that, so hop explicitly rather than assuming.
            DispatchQueue.main.async { HotKeyCenter.shared?.dispatch(carbonID: identifier) }
            return noErr
        }, nil, &reference)

        if status == noErr { handler = reference } else {
            lastError = "Could not install the hotkey handler (\(status))."
        }
    }

    private func dispatch(carbonID: UInt32) {
        guard let id = HotKeyID.allCases.first(where: { $0.carbonID == carbonID }) else {
            return
        }
        onTrigger?(id)
    }

    @discardableResult
    public func registerAll() -> [HotKeyID: RegistrationResult] {
        var results: [HotKeyID: RegistrationResult] = [:]
        for (id, binding) in bindings {
            results[id] = register(id, binding: binding)
        }
        return results
    }

    @discardableResult
    private func register(_ id: HotKeyID, binding: HotKeyBinding) -> RegistrationResult {
        unregister(id)
        guard binding.isPermissible else { return .rejectedInsufficientModifiers }

        var reference: SSEventHotKeyRef?
        let status = ss_register_hotkey(
            UInt32(binding.keyCode), binding.modifiers, id.carbonID, &reference
        )

        if status == OSStatus(kSSEventHotKeyExistsErr) {
            // Another process holds this combination exclusively. Worth saying
            // so: without kEventHotKeyExclusive the registration would appear to
            // succeed and then never fire.
            return .alreadyTakenBySystem
        }
        guard status == noErr, let reference else { return .failed(status) }
        registered[id] = reference
        return .registered
    }

    private func unregister(_ id: HotKeyID) {
        guard let reference = registered.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(reference)
    }

    // MARK: - Editing

    @discardableResult
    public func setBinding(_ binding: HotKeyBinding?, for id: HotKeyID) -> RegistrationResult {
        guard let binding else {
            unregister(id)
            bindings[id] = nil
            saveBindings()
            return .registered
        }
        let result = register(id, binding: binding)
        if result == .registered {
            bindings[id] = binding
            saveBindings()
        }
        return result
    }

    /// Another command in this app already using the combination.
    public func conflict(for binding: HotKeyBinding, excluding id: HotKeyID) -> HotKeyID? {
        bindings.first { $0.key != id && $0.value == binding }?.key
    }

    public func resetToDefaults() {
        for id in HotKeyID.allCases { unregister(id) }
        bindings = Self.shippedDefaults()
        settings[Self.revisionKey] = Self.defaultsRevision
        saveBindings()
        registerAll()
    }

    /// The stored bindings, without constructing a center or registering
    /// anything.
    ///
    /// Diagnostics needs to report the configured shortcuts, and registering
    /// hotkeys as a side effect of asking what they are would be a poor trade.
    public static func configuredBindings(settings: SettingsStore) -> [HotKeyID: HotKeyBinding] {
        let raw = settings[storageKey]
        guard !raw.isEmpty else { return shippedDefaults() }
        let decoded = (try? JSONDecoder().decode(
            [String: HotKeyBinding].self, from: Data(raw.utf8)
        )) ?? [:]
        var bindings = Dictionary(
            uniqueKeysWithValues: decoded.compactMap { key, value in
                HotKeyID(rawValue: key).map { ($0, value) }
            }
        )
        // Fill in commands the stored set predates. A binding that is absent
        // gets its default the next time a center is built, so reporting the
        // gap as "unbound" would describe a state the app is never in.
        for id in HotKeyID.allCases where bindings[id] == nil {
            bindings[id] = id.defaultBinding
        }
        return bindings
    }

    /// System shortcuts that already own a combination.
    ///
    /// Read from `com.apple.symbolichotkeys` rather than `CopySymbolicHotKeys`,
    /// because the preference domain says *which* shortcut it is — IDs 28–31 and
    /// 184 are the screenshot ones — while the Carbon call only says that some
    /// system shortcut holds it.
    public static func systemScreenshotShortcuts() -> [HotKeyBinding] {
        guard
            let domain = UserDefaults.standard
                .persistentDomain(forName: "com.apple.symbolichotkeys"),
            let table = domain["AppleSymbolicHotKeys"] as? [String: Any]
        else { return [] }

        return [28, 29, 30, 31, 184].compactMap { id -> HotKeyBinding? in
            guard
                let entry = table["\(id)"] as? [String: Any],
                entry["enabled"] as? Bool ?? true,
                let value = entry["value"] as? [String: Any],
                let parameters = value["parameters"] as? [Any],
                parameters.count >= 3,
                let keyCode = (parameters[1] as? NSNumber)?.uint16Value,
                let rawModifiers = (parameters[2] as? NSNumber)?.uint32Value
            else { return nil }
            return HotKeyBinding(keyCode: keyCode, modifiers: rawModifiers)
        }
    }
}
