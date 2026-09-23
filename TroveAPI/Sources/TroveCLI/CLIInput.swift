//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import TroveAPIClient


enum CLIError: Error, CustomStringConvertible, Equatable {
    case invalidIdentifier
    case invalidLocale
    case invalidEndpoint
    case invalidCredential
    case invalidInput
    case outputFailed
    case requestFailed
    case httpStatus(Int)

    var description: String {
        switch self {
        case .invalidIdentifier:
            "Expected a UUID."
        case .invalidLocale:
            "Expected a locale with a language and region, for example en-US."
        case .invalidEndpoint:
            "Use an HTTPS API base URL without credentials, query or fragment. HTTP requires an explicitly allowed loopback address."
        case .invalidCredential:
            "Provide one credential source: an owner-only regular file or piped standard input. The bearer token must be nonempty and bounded."
        case .invalidInput:
            "Cannot read the JSON input, or it does not match the operation's API schema."
        case .outputFailed:
            "Cannot write the JSON result. The operation may have succeeded; verify its state before trying again."
        case .requestFailed:
            "The request failed or the reply could not be decoded. No automatic retry was attempted; verify state before retrying a write."
        case .httpStatus(412):
            "The draft changed. Read and review the current draft before submitting a new revision. Your changes were not applied."
        case .httpStatus(let status):
            "The server rejected the request (HTTP \(status)). No automatic retry was attempted."
        }
    }

    static func sanitized(_ error: any Error) -> CLIError {
        if let safe = error as? CLIError {
            return safe
        }
        if let client = error as? ClientError, let safe = client.underlyingError as? CLIError {
            return safe
        }
        return .requestFailed
    }
}


enum CLIInput {
    static func uuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw CLIError.invalidIdentifier
        }
        return uuid
    }

    static func decode<Value: Decodable>(_ type: Value.Type, file: String) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data(file: file))
        } catch {
            throw CLIError.invalidInput
        }
    }

    static func localization(_ value: String) throws -> Components.Schemas.LocalizationKey {
        guard let locale = Components.Schemas.LocalizationKey(value) else {
            throw CLIError.invalidLocale
        }
        return locale
    }

    static func questionnaire(
        file: String,
        name: String,
        locale: Components.Schemas.LocalizationKey
    ) throws -> Components.Schemas.QuestionnaireComponentInput {
        struct ResourceHeader: Decodable {
            let resourceType: String
        }
        do {
            let data = try data(file: file)
            guard let text = String(data: data, encoding: .utf8),
                  try JSONDecoder().decode(ResourceHeader.self, from: data).resourceType == "Questionnaire" else {
                throw CLIError.invalidInput
            }
            return .init(name: name, data: .init([locale: QuestionnaireContent(questionnaire: text)]))
        } catch {
            throw CLIError.invalidInput
        }
    }

    private static func data(file: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        defer { try? handle.close() }
        return try read(handle, limit: 8 * 1024 * 1024)
    }

    static func read(_ handle: FileHandle, limit: Int) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: limit + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else {
                throw CLIError.invalidInput
            }
        }
        return data
    }

    static func write<Value: Encodable>(_ value: Value) throws {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(value)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            throw CLIError.outputFailed
        }
    }

    static func revisionHeader(_ revision: UUID) -> String {
        "\"\(revision.uuidString.lowercased())\""
    }
}
