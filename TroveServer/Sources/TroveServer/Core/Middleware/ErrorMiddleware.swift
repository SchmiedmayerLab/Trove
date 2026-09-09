//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime


struct ErrorMiddleware: ServerMiddleware {
    let logger: Logger
    
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        do {
            return try await next(request, body, metadata)
        } catch {
            let underlying = (error as? OpenAPIRuntime.ServerError)?.underlyingError ?? error
            // Error values and decoding contexts can contain submitted clinical data,
            // credentials, SQL bindings, or paths. Only static type names are diagnostic.
            let diagnostics: Logger.Metadata = [
                "operationID": .string(operationID),
                "errorType": .string(String(reflecting: type(of: underlying)))
            ]

            if let serverError = underlying as? ServerError {
                if serverError.status.code >= 500 {
                    logger.error("Server operation failed", metadata: diagnostics)
                    return ServerError(
                        status: serverError.status,
                        title: "Server Error",
                        detail: "An unexpected error occurred"
                    ).httpResponse
                }
                return serverError.httpResponse
            }
            
            if underlying is DecodingError {
                logger.info("Invalid request body", metadata: diagnostics)
                return ServerError.invalidRequestBody.httpResponse
            }

            if let conversionError = underlying as? any HTTPResponseConvertible,
               (400..<500).contains(conversionError.httpStatus.code) {
                // Preserve the runtime's request-error classification, never its
                // description, response body or headers, which may contain input.
                logger.info("Invalid request", metadata: diagnostics)
                return ServerError(
                    status: conversionError.httpStatus,
                    title: "Invalid Request",
                    detail: "The request could not be decoded"
                ).httpResponse
            }

            logger.critical("Unexpected server error", metadata: diagnostics)
            return ServerError.unexpectedError.httpResponse
        }
    }
}
