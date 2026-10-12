// swift-tools-version:6.2
//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import class Foundation.ProcessInfo
import PackageDescription


let package = Package(
    name: "TroveServer",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.26.0"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        // 🪶 Fluent driver for SQLite (used for testing).
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // OpenAPI runtime & transport
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.12.1"),
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.0.0"),
        // Shared API types, client, and server stubs (inlined in this monorepo)
        .package(path: "../TroveAPI"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.4"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        // Match the API's immutable Grove revision until the shared products have a tagged release.
        .package(url: "https://github.com/SchmiedmayerLab/Grove.git", revision: "dfa881ff265507306ebbcb9576499688c8909afd"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
        .package(url: "https://github.com/SchmiedmayerLab/FHIRModels.git", .upToNextMinor(from: "0.9.3"))
    ] + swiftLintPackage(),
    targets: [
        .executableTarget(
            name: "TroveServer",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "TroveAPIServer", package: "TroveAPI"),
                .product(name: "GroveStudyDefinition", package: "Grove"),
                .product(name: "GroveHealthKit", package: "Grove"),
                .product(name: "GroveHealthKitBulkExport", package: "Grove"),
                .product(name: "Grove", package: "Grove"),
                .product(name: "GroveFoundation", package: "Grove"),
                .product(name: "GroveFHIRContract", package: "Grove"),
                .product(name: "GroveQuestionnaireFHIR", package: "Grove"),
                .target(name: "GroveVapor"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "GroveLocalization", package: "Grove"),
                .product(name: "SotoS3", package: "soto"),
                .product(name: "ModelsR4", package: "FHIRModels")
            ],
            swiftSettings: swiftSettings,
            plugins: [] + swiftLintPlugin()
        ),
        .target(
            name: "GroveVapor",
            dependencies: [
                .product(name: "Grove", package: "Grove"),
                .product(name: "Vapor", package: "vapor")
            ],
            swiftSettings: swiftSettings,
            plugins: [] + swiftLintPlugin()
        ),
        .testTarget(
            name: "TroveServerTests",
            dependencies: [
                .target(name: "TroveServer"),
                .product(name: "TroveAPIClient", package: "TroveAPI"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "GroveFHIRContract", package: "Grove"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "JWTKit", package: "jwt-kit")
            ],
            exclude: ["Resources/ImmutablePointEvent.json.license", "Resources/HealthKitPointEvent.json.license"],
            resources: [.copy("Resources/ImmutablePointEvent.json"), .copy("Resources/HealthKitPointEvent.json")],
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
    // Fully quit Xcode and open again with `open --env TROVE_DEVELOPMENT_SWIFTLINT /Applications/Xcode.app`
    if ProcessInfo.processInfo.environment["TROVE_DEVELOPMENT_SWIFTLINT"] != nil {
        [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint")]
    } else {
        []
    }
}

func swiftLintPackage() -> [PackageDescription.Package.Dependency] {
    if ProcessInfo.processInfo.environment["TROVE_DEVELOPMENT_SWIFTLINT"] != nil {
        [.package(url: "https://github.com/realm/SwiftLint.git", from: "0.55.1")]
    } else {
        []
    }
}
