//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import TroveAPIServer


/// An error that directly models an RFC 7807 Problem Details response.
struct ServerError: Error, Sendable {
    static let jsonBodyRequired = badRequest("Request body must be JSON")
    static let invalidRequestBody = badRequest("Invalid request body format")
    static let missingToken = unauthorized("Missing Authorization header")
    static let invalidToken = unauthorized("Invalid or expired token")
    static let forbidden = Self(status: .forbidden, title: "Forbidden", detail: "Insufficient permissions")
    static let unexpectedError = internalServerError("An unexpected error occurred")
    static let endpointNotImplemented = Self(status: .notImplemented, title: "Not Implemented", detail: "Endpoint not implemented")

    let status: HTTPResponse.Status
    let title: String
    let detail: String

    static func badRequest(_ detail: String) -> Self {
        Self(status: .badRequest, title: "Bad Request", detail: detail)
    }

    static func unauthorized(_ detail: String) -> Self {
        Self(status: .unauthorized, title: "Unauthorized", detail: detail)
    }

    static func forbidden(_ detail: String) -> Self {
        Self(status: .forbidden, title: "Forbidden", detail: detail)
    }

    static func notFound(_ detail: String) -> Self {
        Self(status: .notFound, title: "Not Found", detail: detail)
    }

    static func notFound(resource: String, identifier: String) -> Self {
        .notFound("\(resource) with identifier '\(identifier)' was not found")
    }

    static func conflict(_ detail: String) -> Self {
        Self(status: .conflict, title: "Conflict", detail: detail)
    }

    static func conflict(resource: String, identifier: String) -> Self {
        .conflict("\(resource) with identifier '\(identifier)' already exists")
    }

    static func internalServerError(_ detail: String) -> Self {
        Self(status: .internalServerError, title: "Internal Server Error", detail: detail)
    }
}

extension ServerError {
    var httpResponse: (HTTPResponse, HTTPBody?) {
        let problemDetails = Components.Schemas.ProblemDetails(title: title, status: status.code, detail: detail)

        var headerFields = HTTPFields()
        headerFields[.contentType] = "application/problem+json; charset=utf-8"

        let body: HTTPBody?
        if let data = try? JSONEncoder().encode(problemDetails) {
            body = HTTPBody(data)
        } else {
            body = nil
        }

        return (HTTPResponse(status: status, headerFields: headerFields), body)
    }
}
