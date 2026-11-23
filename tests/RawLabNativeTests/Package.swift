// swift-tools-version: 6.0
import Foundation
import PackageDescription

let rootPackageIdentity = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .lastPathComponent

let package = Package(
    name: "RawLabNativeTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .testTarget(
            name: "RawLabNativeTests",
            dependencies: [
                .product(name: "RawLabNative", package: rootPackageIdentity),
                .product(name: "RawLabKit", package: rootPackageIdentity),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
