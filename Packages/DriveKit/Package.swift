// swift-tools-version: 6.2
import PackageDescription

// Sensors / Recording / Storage / Replay / Export live here, nonisolated by default (PLAN §14).
// Every module builds on macOS too so `swift test` runs on the host; iOS-only sensor code is
// guarded with `#if os(iOS)`.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "DriveKit",
    defaultLocalization: "en",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "DriveDomain", targets: ["DriveDomain"]),
        .library(name: "DriveSensors", targets: ["DriveSensors"]),
        .library(name: "DriveStorage", targets: ["DriveStorage"]),
        .library(name: "DriveRecording", targets: ["DriveRecording"]),
        .library(name: "DriveReplay", targets: ["DriveReplay"]),
        .library(name: "DriveExport", targets: ["DriveExport"]),
    ],
    targets: [
        .target(name: "DriveDomain", swiftSettings: swiftSettings),
        .target(name: "DriveSensors", dependencies: ["DriveDomain"], swiftSettings: swiftSettings),
        .target(name: "DriveStorage", dependencies: ["DriveDomain"], swiftSettings: swiftSettings),
        .target(name: "DriveReplay", dependencies: ["DriveDomain", "DriveStorage"], swiftSettings: swiftSettings),
        .target(
            name: "DriveRecording",
            dependencies: ["DriveDomain", "DriveSensors", "DriveStorage", "DriveReplay"],
            swiftSettings: swiftSettings
        ),
        .target(name: "DriveExport", dependencies: ["DriveDomain", "DriveStorage", "DriveReplay"], swiftSettings: swiftSettings),

        .testTarget(name: "DriveStorageTests", dependencies: ["DriveStorage"], swiftSettings: swiftSettings),
        .testTarget(name: "DriveSensorsTests", dependencies: ["DriveSensors"], swiftSettings: swiftSettings),
        .testTarget(name: "DriveRecordingTests", dependencies: ["DriveRecording", "DriveSensors", "DriveReplay"], swiftSettings: swiftSettings),
        .testTarget(name: "DriveReplayTests", dependencies: ["DriveReplay", "DriveSensors", "DriveRecording"], swiftSettings: swiftSettings),
        .testTarget(name: "DriveExportTests", dependencies: ["DriveExport", "DriveSensors", "DriveRecording"], swiftSettings: swiftSettings),
    ]
)
