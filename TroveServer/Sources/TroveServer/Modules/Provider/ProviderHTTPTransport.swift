//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AsyncHTTPClient
import Foundation
import Vapor


struct ProviderHTTPTransport: Sendable {
    enum Endpoint: String, Sendable, CaseIterable {
        case withingsToken = "https://wbsapi.withings.net/v2/oauth2"
        case withingsMeasures = "https://wbsapi.withings.net/measure"
        case ouraToken = "https://api.ouraring.com/oauth/token"
        case ouraIdentity = "https://api.ouraring.com/v2/usercollection/personal_info"
        case ouraVO2Max = "https://api.ouraring.com/v2/usercollection/vO2_max"
        case googleToken = "https://oauth2.googleapis.com/token"
        case googleIdentity = "https://health.googleapis.com/v4/users/me/identity"

        var method: HTTPMethod {
            switch self {
            case .ouraIdentity, .ouraVO2Max, .googleIdentity: .GET
            case .withingsToken, .withingsMeasures, .ouraToken, .googleToken: .POST
            }
        }
    }

    let send: @Sendable (Endpoint, Data, String?, Int) async throws -> Data

    init(application: Application) throws {
        let policy = try application.outboundTransport
        for endpoint in Endpoint.allCases { try policy.validateEndpoint(endpoint.rawValue) }
        let client = application.http.client.shared
        send = { endpoint, body, bearer, maximumBytes in
            var components = URLComponents(string: endpoint.rawValue)
            if endpoint.method == .GET, !body.isEmpty {
                guard body.count <= 131_072, let query = String(data: body, encoding: .utf8) else { throw ProviderFailure.invalidPayload }
                components?.percentEncodedQuery = query
            }
            guard let url = components?.url else { throw ProviderFailure.invalidConfiguration }
            var request = HTTPClientRequest(url: url.absoluteString)
            request.method = endpoint.method
            request.headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"]
            request.headers.add(name: "User-Agent", value: "Trove")
            if let bearer { request.headers.add(name: "Authorization", value: "Bearer " + bearer) }
            if endpoint.method == .POST {
                request.body = .bytes(ByteBuffer(data: body))
            }
            do {
                let response = try await client.execute(request, timeout: .seconds(30))
                if response.status == .tooManyRequests || response.status == .serviceUnavailable {
                    throw ProviderTransportRetry.parse(response.headers.first(name: "Retry-After"))
                }
                guard response.status == .ok else { throw ProviderFailure.unavailable }
                let bytes = Data(try await response.body.collect(upTo: maximumBytes).readableBytesView)
                try Task.checkCancellation()
                return bytes
            } catch let retry as ProviderTransportRetry {
                throw retry
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Headers, URL/body diagnostics and provider error responses may contain credentials or clinical data.
                throw ProviderFailure.unavailable
            }
        }
    }

    init(send: @escaping @Sendable (Endpoint, Data, String?, Int) async throws -> Data) { self.send = send }

    static func form(_ fields: [String: String]) throws -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let parts = try fields.keys.sorted().map { key in
            guard let value = fields[key], let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed),
                  let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) else { throw ProviderFailure.invalidPayload }
            return encodedKey + "=" + encodedValue
        }
        let result = Data(parts.joined(separator: "&").utf8)
        guard result.count <= 131_072 else { throw ProviderFailure.capacityExceeded }
        return result
    }
}
