// swift-tools-version: 6.2
import PackageDescription

// The Android app's way into DriveKit (docs/ANDROID_SPIKE.md): a shared library with JNI entry points, built with
// the Swift SDK for Android and dropped into app/src/main/jniLibs.
let package = Package(
    name: "DriveKitBridge",
    products: [
        .library(name: "DriveKitBridge", type: .dynamic, targets: ["DriveKitBridge"]),
    ],
    dependencies: [
        .package(path: "../../../Packages/DriveKit"),
    ],
    targets: [
        .systemLibrary(name: "CJNI", path: "Sources/CJNI"),
        .target(
            name: "DriveKitBridge",
            dependencies: [
                "CJNI",
                .product(name: "DriveDomain", package: "DriveKit"),
                .product(name: "DriveStorage", package: "DriveKit"),
                .product(name: "DriveReplay", package: "DriveKit"),
                .product(name: "DriveExport", package: "DriveKit"),
            ]
        ),
    ]
)
