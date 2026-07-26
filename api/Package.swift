// swift-tools-version:6.0

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
    name: "StudyPlatformAPI",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
        .macOS(.v15),
        .macCatalyst(.v18)
    ],
    products: [
        .library(name: "StudyPlatformAPITypes", targets: ["StudyPlatformAPITypes"]),
        .library(name: "StudyPlatformAPIClient", targets: ["StudyPlatformAPIClient"]),
        .library(name: "StudyPlatformAPIServer", targets: ["StudyPlatformAPIServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/SchmiedmayerLab/Spezi.git", branch: "add-spezivapor")
    ] + swiftLintPackage(),
    targets: [
        .target(
            name: "StudyPlatformAPITypes",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "SpeziLocalization", package: "Spezi"),
                .product(name: "SpeziHealthKit", package: "Spezi"),
                .product(name: "SpeziStudyDefinition", package: "Spezi")
            ],
            plugins: [] + swiftLintPlugin()
        ),
        .target(
            name: "StudyPlatformAPIClient",
            dependencies: [
                .target(name: "StudyPlatformAPITypes"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession")
            ],
            plugins: [] + swiftLintPlugin()
        ),
        .target(
            name: "StudyPlatformAPIServer",
            dependencies: [
                .target(name: "StudyPlatformAPITypes"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
            ],
            plugins: [] + swiftLintPlugin()
        ),
        .executableTarget(
            name: "StudyPlatformAPIGenerator",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            plugins: [] + swiftLintPlugin()
        ),
        .testTarget(
            name: "StudyPlatformAPITests",
            dependencies: [
                .target(name: "StudyPlatformAPITypes"),
                .target(name: "StudyPlatformAPIClient"),
                .target(name: "StudyPlatformAPIServer")
            ],
            plugins: [] + swiftLintPlugin()
        )
    ]
)


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
