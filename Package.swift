// swift-tools-version: 6.2

import PackageDescription

/// Compiler settings applied to every first-party target.
///
/// - `ExistentialAny` makes every existential explicit (`any Protocol`).
/// - `InternalImportsByDefault` forces `public import` for dependencies that leak into a public API,
///   which keeps framework types from escaping a layer by accident.
/// - `MemberImportVisibility` rejects members that are only visible through a transitive import.
let strictSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "borba-scientific-engine",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.2"),
    ],
    targets: [
        .target(
            name: "BorbaScientificEngine",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Vapor", package: "vapor"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "UnitTests",
            dependencies: [
                "BorbaScientificEngine",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/Unit",
            swiftSettings: strictSwiftSettings
        ),
    ]
)
