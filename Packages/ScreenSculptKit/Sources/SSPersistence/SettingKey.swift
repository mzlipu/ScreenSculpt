// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation

/// One preference, described once.
///
/// Every setting in the app is a `SettingKey` — including the ones with no UI.
/// That is deliberate: it means `defaults write app.screensculpt.ScreenSculpt
/// <name> <value>` works for all of them without a line of extra code, so power
/// users get the expert knobs for free and the settings window stays uncluttered.
public struct SettingKey<Value>: Sendable where Value: Sendable {
    public let name: String
    public let defaultValue: Value

    /// Reads the raw plist value. Separate from `defaultValue` so enums can be
    /// stored as readable strings rather than opaque integers.
    public let decode: @Sendable (Any?) -> Value?
    public let encode: @Sendable (Value) -> Any

    public init(
        _ name: String,
        default defaultValue: Value,
        decode: @escaping @Sendable (Any?) -> Value?,
        encode: @escaping @Sendable (Value) -> Any
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.decode = decode
        self.encode = encode
    }
}

extension SettingKey where Value == Bool {
    public init(_ name: String, default defaultValue: Bool) {
        self.init(
            name, default: defaultValue,
            decode: { $0 as? Bool }, encode: { $0 }
        )
    }
}

extension SettingKey where Value == Int {
    public init(_ name: String, default defaultValue: Int) {
        self.init(
            name, default: defaultValue,
            decode: { ($0 as? NSNumber)?.intValue }, encode: { $0 }
        )
    }
}

extension SettingKey where Value == Double {
    public init(_ name: String, default defaultValue: Double) {
        self.init(
            name, default: defaultValue,
            decode: { ($0 as? NSNumber)?.doubleValue }, encode: { $0 }
        )
    }
}

extension SettingKey where Value == String {
    public init(_ name: String, default defaultValue: String) {
        self.init(
            name, default: defaultValue,
            decode: { $0 as? String }, encode: { $0 }
        )
    }
}

extension SettingKey where Value: RawRepresentable & Sendable, Value.RawValue == String {
    /// Enums are stored as their raw string, so `defaults read` is legible and
    /// `defaults write … saveFormat png` does the obvious thing.
    public init(_ name: String, default defaultValue: Value) {
        self.init(
            name, default: defaultValue,
            decode: { ($0 as? String).flatMap(Value.init(rawValue:)) },
            encode: { $0.rawValue }
        )
    }
}

extension SettingKey where Value == URL? {
    /// Folders are stored as a security-scoped bookmark, not a path.
    ///
    /// Users rename parent folders, and a stored path silently starts writing
    /// somewhere else — or nowhere.
    public init(bookmark name: String) {
        self.init(
            name, default: nil,
            decode: { raw in
                guard let data = raw as? Data else { return nil }
                var stale = false
                return try? URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
            },
            encode: { url in
                guard let url else { return Data() }
                return (try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )) ?? Data()
            }
        )
    }
}
