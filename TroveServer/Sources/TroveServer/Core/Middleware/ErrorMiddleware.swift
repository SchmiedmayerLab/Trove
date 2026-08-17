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

            if let serverError = underlying as? ServerError {
                return serverError.httpResponse
            }
            
            if underlying is DecodingError {
                logger.info("\(String(reflecting: underlying))")
                return ServerError.invalidRequestBody.httpResponse
            }

            logger.critical(
                "Unexpected error",
                metadata: [
                    "operationID": .string(operationID),
                    "errorType": .string(String(reflecting: type(of: underlying))),
                    "error": .string(String(reflecting: underlying))
                ]
            )

            
            return ServerError.unexpectedError.httpResponse
        }
    }
}
