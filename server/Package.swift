// swift-tools-version:6.2
//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import class Foundation.ProcessInfo
import PackageDescription


let package = Package(
    name: "StudyPlatformServer",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        // 🪶 Fluent driver for SQLite (used for testing).
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // OpenAPI runtime & transport
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.7.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.0.0"),
        // Shared API types, client, and server stubs (inlined in this monorepo)
        .package(path: "../api"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        // SchmiedmayerLab/Spezi add-spezivapor branch (SpeziVapor not yet in a published tag).
        .package(url: "https://github.com/SchmiedmayerLab/Spezi.git", branch: "add-spezivapor"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/FHIRModels.git", from: "0.8.0")
    ] + swiftLintPackage(),
    targets: [
        .executableTarget(
            name: "StudyPlatformServer",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "StudyPlatformAPIServer", package: "api"),
                .product(name: "SpeziStudyDefinition", package: "Spezi"),
                .product(name: "SpeziHealthKit", package: "Spezi"),
                .product(name: "SpeziHealthKitBulkExport", package: "Spezi"),
                .product(name: "Spezi", package: "Spezi"),
                .product(name: "SpeziVapor", package: "Spezi"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SpeziLocalization", package: "Spezi"),
                .product(name: "SotoS3", package: "soto"),
                .product(name: "ModelsR4", package: "FHIRModels")
            ],
            swiftSettings: swiftSettings,
            plugins: [] + swiftLintPlugin()
        ),
        .testTarget(
            name: "StudyPlatformServerTests",
            dependencies: [
                .target(name: "StudyPlatformServer"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "JWTKit", package: "jwt-kit")
            ],
            swiftSettings: swiftSettings,
            plugins: [] + swiftLintPlugin()
        )
    ]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny")
    ]
}

func swiftLintPlugin() -> [Target.PluginUsage] {
    // Fully quit Xcode and open again with `open --env SPEZI_DEVELOPMENT_SWIFTLINT /Applications/Xcode.app`
    if ProcessInfo.processInfo.environment["SPEZI_DEVELOPMENT_SWIFTLINT"] != nil {
        [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")]
    } else {
        []
    }
}

func swiftLintPackage() -> [PackageDescription.Package.Dependency] {
    if ProcessInfo.processInfo.environment["SPEZI_DEVELOPMENT_SWIFTLINT"] != nil {
        [.package(url: "https://github.com/realm/SwiftLint.git", from: "0.55.1")]
    } else {
        []
    }
}
