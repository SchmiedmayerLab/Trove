//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if os(macOS) || os(Linux)
import ArgumentParser
import Foundation


struct GenerateAPI: ParsableCommand {
    private struct Target {
        let label: String
        let config: String
        let outputDirectory: String
    }

    static let configuration = CommandConfiguration(
        commandName: "generate-api",
        abstract: "Generate OpenAPI types, client, and server Swift code."
    )

    private static let allTargets: [Target] = [
        Target(
            label: "Types",
            config: "openapi-generator-config-types.yaml",
            outputDirectory: "Sources/TroveAPITypes/Generated"
        ),
        Target(
            label: "Client",
            config: "openapi-generator-config-client.yaml",
            outputDirectory: "Sources/TroveAPIClient/Generated"
        ),
        Target(
            label: "Server",
            config: "openapi-generator-config-server.yaml",
            outputDirectory: "Sources/TroveAPIServer/Generated"
        )
    ]

    @Option(name: .long, help: "Path to the TroveAPI package.") var packagePath: String = "."
    @Option(name: .long, help: "Path to the OpenAPI spec file, relative to the package.") var spec: String = "openapi.yaml"
    @Flag(name: .long, help: "Generate the types target.") var types = false
    @Flag(name: .long, help: "Generate the client target.") var client = false
    @Flag(name: .long, help: "Generate the server target.") var server = false

    private var generateAll: Bool {
        !types && !client && !server
    }

    mutating func run() throws {
        let selectedTargets: [Target]
        if generateAll {
            selectedTargets = Self.allTargets
        } else {
            selectedTargets = Self.allTargets.filter { target in
                switch target.label {
                case "Types": types
                case "Client": client
                case "Server": server
                default: false
                }
            }
        }

        for target in selectedTargets {
            try generate(target)
        }
    }

    private func generate(_ target: Target) throws {
        print("Generating \(target.label)...")

        let package = URL(fileURLWithPath: packagePath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Run the generator out of this package's dependencies rather than expecting it on PATH.
        process.arguments = [
            "swift", "run", "--package-path", package.path, "swift-openapi-generator",
            "generate", package.appendingPathComponent(spec).path,
            "--config", package.appendingPathComponent(target.config).path,
            "--output-directory", package.appendingPathComponent(target.outputDirectory).path
        ]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExitCode(process.terminationStatus)
        }
    }
}
#endif
