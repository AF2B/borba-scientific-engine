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
    products: [
        .executable(name: "borba-scientific-engine", targets: ["Run"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/vapor/async-kit.git", from: "1.22.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-kit.git", from: "1.57.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.14.0"),
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.17.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.1"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.36.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.2"),
    ],
    targets: [
        .target(
            name: "BorbaScientificCore",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "BorbaScientificPersistence",
            dependencies: [
                "BorbaScientificCore",
                .product(name: "AsyncKit", package: "async-kit"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "PostgresKit", package: "postgres-kit"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "SQLKit", package: "sql-kit"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "BorbaScientificEngine",
            dependencies: [
                "BorbaScientificCore",
                "BorbaScientificPersistence",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Vapor", package: "vapor"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "Run",
            dependencies: ["BorbaScientificEngine"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "TestSupport",
            dependencies: ["BorbaScientificCore"],
            path: "Tests/Support",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "IntegrationSupport",
            dependencies: [
                "BorbaScientificCore",
                "BorbaScientificPersistence",
                "TestSupport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/IntegrationSupport",
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "HTTPSupport",
            dependencies: [
                "BorbaScientificCore",
                "BorbaScientificEngine",
                "TestSupport",
                .product(name: "InMemoryLogging", package: "swift-log"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            path: "Tests/HTTPSupport",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "UnitTests",
            dependencies: [
                "BorbaScientificCore",
                "BorbaScientificEngine",
                "TestSupport",
                .product(name: "InMemoryLogging", package: "swift-log"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Tests/Unit",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "ContractTests",
            dependencies: [
                "BorbaScientificCore",
                "BorbaScientificEngine",
                "HTTPSupport",
                "TestSupport",
                .product(name: "InMemoryLogging", package: "swift-log"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            path: "Tests/Contract",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "BorbaScientificCore",
                "BorbaScientificEngine",
                "BorbaScientificPersistence",
                "HTTPSupport",
                "IntegrationSupport",
                "TestSupport",
                .product(name: "InMemoryLogging", package: "swift-log"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQL", package: "fluent-kit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/Integration",
            swiftSettings: strictSwiftSettings
        ),
    ]
)
