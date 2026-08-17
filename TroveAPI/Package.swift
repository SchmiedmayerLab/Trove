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
        .library(name: "TroveAPIServer", targets: ["TroveAPIServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // TroveAPIGenerator runs this package's executable; no target links against it.
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.10.0"),
        .package(url: "https://github.com/SchmiedmayerLab/Spezi.git", branch: "grove")
    ] + swiftLintPackage(),
    targets: [
        .target(
            name: "TroveAPITypes",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "GroveLocalization", package: "Spezi"),
                .product(name: "GroveHealthKit", package: "Spezi"),
                .product(name: "GroveStudyDefinition", package: "Spezi")
            ],
            plugins: [] + swiftLintPlugin()
        ),
        .target(
            name: "TroveAPIClient",
            dependencies: [
                .target(name: "TroveAPITypes"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession")
            ],
            plugins: [] + swiftLintPlugin()
        ),
        .target(
            name: "TroveAPIServer",
            dependencies: [
                .target(name: "TroveAPITypes"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
            ],
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
