// swift-tools-version:6.0

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
    name: "TroveAPI",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
        .macOS(.v15),
        .macCatalyst(.v18)
    ],
    products: [
        .library(name: "TroveAPITypes", targets: ["TroveAPITypes"]),
        .library(name: "TroveAPIClient", targets: ["TroveAPIClient"]),
        .library(name: "TroveHealthKit", targets: ["TroveHealthKit"]),
        .library(name: "TroveAPIServer", targets: ["TroveAPIServer"]),
        .executable(name: "trove", targets: ["TroveCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.12.1"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", from: "1.3.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.15.1"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        // TroveAPIGenerator runs this package's executable; no target links against it.
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.13.1"),
        // Use the immutable PR revision until its products are available in a tagged release.
        .package(url: "https://github.com/SchmiedmayerLab/Grove.git", revision: "dfa881ff265507306ebbcb9576499688c8909afd")
    ] + swiftLintPackage(),
    targets: [
        .systemLibrary(name: "CTroveDeliverySQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "TroveAPITypes",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GroveFHIRContract", package: "Grove"),
                .product(name: "GroveLocalization", package: "Grove"),
                .product(name: "GroveHealthKit", package: "Grove"),
                .product(name: "GroveStudyDefinition", package: "Grove")
            ],
            exclude: ["Generated/Types.swift.license"],
            plugins: [] + swiftLintPlugin()
        ),
        .target(
            name: "TroveAPIClient",
            dependencies: [
                .target(name: "CTroveDeliverySQLite"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GroveFHIRContract", package: "Grove"),
                .target(name: "TroveAPITypes"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession")
            ],
            exclude: ["Generated/Client.swift.license"],
            plugins: [] + swiftLintPlugin()
        ),
        .target(
            name: "TroveHealthKit",
            dependencies: [
                .target(name: "TroveAPIClient"),
                .product(name: "GroveFHIRContract", package: "Grove"),
                .product(
                    name: "GroveHealthKit", package: "Grove", condition: .when(platforms: [.iOS, .macOS, .watchOS, .visionOS, .macCatalyst])
                ),
                .product(
                    name: "GroveHealthKitFHIR", package: "Grove", condition: .when(platforms: [.iOS, .macOS, .watchOS, .visionOS, .macCatalyst])
                )
            ],
            plugins: [] + swiftLintPlugin()
        ),
        .target(
            name: "TroveAPIServer",
            dependencies: [
                .target(name: "TroveAPITypes"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
            ],
            exclude: ["Generated/Server.swift.license"],
            plugins: [] + swiftLintPlugin()
        ),
        .executableTarget(
            name: "TroveCLI",
            dependencies: [
                .target(name: "TroveAPIClient"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession")
            ],
            plugins: [] + swiftLintPlugin()
        ),
        .testTarget(
            name: "TroveCLITests",
            dependencies: [.target(name: "TroveCLI")],
            plugins: [] + swiftLintPlugin()
        ),
        .executableTarget(
            name: "TroveAPIGenerator",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            plugins: [] + swiftLintPlugin()
        ),
        .testTarget(
            name: "TroveAPITests",
            dependencies: [
                .target(name: "TroveHealthKit"),
                .target(name: "TroveAPITypes"),
                .target(name: "TroveAPIClient"),
                .target(name: "TroveAPIServer")
            ],
            plugins: [] + swiftLintPlugin()
        )
    ]
)


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
