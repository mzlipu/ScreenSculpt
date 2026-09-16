// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import PackageDescription

// MARK: - Per-target concurrency posture
//
// UI targets default to MainActor isolation, so UI code never writes @MainActor.
// Compute targets default to nonisolated, so pure logic never accidentally
// inherits it. This split removes the overwhelming majority of Swift 6
// annotation churn and is the reason the logic lives in a package at all.

let uiSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .treatAllWarnings(as: .error),
]

let computeSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .treatAllWarnings(as: .error),
]

// MARK: - Dependency graph
//
//   CHotKeyShim   SSGeometry
//                     |
//                 SSImaging ----+---------+--------------+----------+
//                     |         |         |              |          |
//               SSAnnotations SSStitch SSMeasure   SSRecognition  SSExport
//                     |                                              ^
//                SSDocument ----------------------------->  SSPersistence
//                     |
//                  SSRender      SSPlatform <- SSCapture, SSHotKeys(+CHotKeyShim)
//                     |
//       SSEditorUI  SSCaptureUI  SSSettingsUI  SSStatusUI
//
// Never add an edge that points leftward.
//
// Note SwiftPM does NOT stop a target importing a system framework it has not
// declared — compiling `import AppKit` inside SSStitch succeeds. This graph
// documents intent; the headless boundary is enforced by the SwiftLint rule
// `no_appkit_in_compute_modules`.

let package = Package(
    name: "ScreenSculptKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScreenSculptKit", targets: [
            "SSEditorUI", "SSCaptureUI", "SSSettingsUI", "SSStatusUI",
        ]),
        .library(name: "SSGeometry", targets: ["SSGeometry"]),
        .library(name: "SSRecognitionUI", targets: ["SSRecognitionUI"]),
        .library(name: "SSStitch", targets: ["SSStitch"]),
        .library(name: "SSMeasure", targets: ["SSMeasure"]),
        .library(name: "SSRender", targets: ["SSRender"]),
    ],
    targets: [

        // MARK: Foundation layer (no AppKit anywhere below this line)

        .target(
            name: "SSGeometry",
            swiftSettings: computeSettings
        ),
        .target(
            name: "SSImaging",
            dependencies: ["SSGeometry"],
            swiftSettings: computeSettings
        ),

        // MARK: Model layer

        .target(
            name: "SSAnnotations",
            dependencies: ["SSGeometry", "SSImaging"],
            swiftSettings: computeSettings
        ),
        .target(
            name: "SSPersistence",
            dependencies: ["SSGeometry"],
            swiftSettings: computeSettings
        ),
        .target(
            name: "SSDocument",
            dependencies: ["SSGeometry", "SSImaging", "SSAnnotations"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "SSRender",
            dependencies: [
                "SSGeometry", "SSImaging", "SSAnnotations", "SSDocument", "SSRecognition",
            ],
            swiftSettings: uiSettings
        ),

        // MARK: Pure compute subsystems — all headlessly testable

        .target(
            name: "SSStitch",
            dependencies: ["SSGeometry", "SSImaging"],
            swiftSettings: computeSettings
        ),
        .target(
            name: "SSMeasure",
            dependencies: ["SSGeometry", "SSImaging"],
            swiftSettings: computeSettings
        ),
        .target(
            name: "SSRecognition",
            dependencies: ["SSGeometry", "SSImaging"],
            swiftSettings: computeSettings
        ),
        .target(
            name: "SSExport",
            dependencies: ["SSGeometry", "SSImaging", "SSDocument", "SSRender", "SSPersistence"],
            swiftSettings: computeSettings
        ),

        // MARK: Platform layer
        //
        // Carbon's hotkey API is declared in no macOS 26 SDK header, but the
        // symbols are still exported from HIToolbox.tbd. CHotKeyShim declares
        // the prototypes by hand. Isolating it means the day Apple drops the
        // exports, exactly one file fails to link.

        .target(
            name: "CHotKeyShim",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .target(
            name: "SSPlatform",
            // SSImaging for ClipboardWriter, which encodes before writing to
            // the pasteboard.
            dependencies: ["SSGeometry", "SSImaging", "SSPersistence"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "SSHotKeys",
            dependencies: ["CHotKeyShim", "SSPersistence", "SSPlatform"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "SSCapture",
            dependencies: ["SSGeometry", "SSImaging", "SSPlatform", "SSStitch"],
            swiftSettings: uiSettings
        ),

        // MARK: UI layer

        .target(
            name: "SSCaptureUI",
            dependencies: ["SSCapture", "SSPlatform", "SSMeasure", "SSRecognition"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "SSEditorUI",
            dependencies: [
                "SSAnnotations", "SSDocument", "SSRender", "SSMeasure",
                "SSRecognition", "SSRecognitionUI", "SSExport", "SSPlatform", "SSCapture",
            ],
            swiftSettings: uiSettings
        ),
        .target(
            name: "SSRecognitionUI",
            dependencies: ["SSRecognition"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "SSSettingsUI",
            dependencies: ["SSPersistence", "SSPlatform", "SSHotKeys"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "SSStatusUI",
            dependencies: ["SSPlatform", "SSPersistence", "SSCapture"],
            swiftSettings: uiSettings
        ),

        // MARK: Tests — every one of these runs headlessly, with no window
        // server, no TCC grant and no app launch.

        .testTarget(
            name: "SSGeometryTests",
            dependencies: ["SSGeometry"],
            swiftSettings: computeSettings
        ),
        .testTarget(
            name: "SSImagingTests",
            dependencies: ["SSImaging"],
            swiftSettings: computeSettings
        ),
        .testTarget(
            name: "SSAnnotationsTests",
            dependencies: ["SSAnnotations"],
            swiftSettings: computeSettings
        ),
        .testTarget(
            name: "SSDocumentTests",
            dependencies: ["SSDocument"],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "SSStitchTests",
            dependencies: ["SSStitch"],
            swiftSettings: computeSettings
        ),
        .testTarget(
            name: "SSCaptureTests",
            dependencies: ["SSCapture", "SSStitch", "SSImaging", "SSGeometry"],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "SSMeasureTests",
            dependencies: ["SSMeasure", "SSImaging"],
            swiftSettings: computeSettings
        ),
        .testTarget(
            name: "SSExportTests",
            dependencies: ["SSExport"],
            swiftSettings: computeSettings
        ),
        .testTarget(
            name: "SSPlatformTests",
            dependencies: ["SSPlatform"],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "SSRecognitionTests",
            dependencies: ["SSRecognition", "SSImaging"],
            swiftSettings: computeSettings
        ),
        .testTarget(
            name: "SSEditorUITests",
            dependencies: ["SSEditorUI", "SSDocument", "SSAnnotations"],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "SSRenderTests",
            dependencies: ["SSRender", "SSDocument", "SSAnnotations"],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "SSPersistenceTests",
            dependencies: ["SSPersistence"],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "SSHotKeysTests",
            dependencies: ["SSHotKeys"],
            swiftSettings: uiSettings
        ),
    ]
)
