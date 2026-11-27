//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AsyncHTTPClient
import Foundation
import NIOCore
import OpenAPIRuntime
import SotoS3
import Vapor


/// Streams objects to and from S3-compatible storage.
///
/// An upload holds a bounded amount of its body in memory, independent of the object size: the 64 KiB chunk being
/// signed, the chunks the storage connection has accepted up to its write-buffer limit, and at most
/// ``EventLoopPacedBody/window`` body chunks queued ahead of that connection. Reads use the HTTP client's response
/// backpressure.
final class S3ObjectStorageProvider: ObjectStorageProvider, Sendable {
    private let httpClient: HTTPClient
    private let eventLoop: any EventLoop
    private let client: AWSClient
    private let s3: S3
    private let bucket: String

    init(application: Application, config: S3ObjectStorageConfiguration) throws {
        try application.outboundTransport.validateEndpoint(config.endpoint)
        // Every storage connection runs on this one event loop, so an upload can pace its body against it. The client
        // shares the application's transport configuration.
        let eventLoop = application.eventLoopGroup.next()
        let httpClient = HTTPClient(
            eventLoopGroup: eventLoop,
            configuration: application.http.client.configuration,
            backgroundActivityLogger: application.logger
        )
        let client = AWSClient(
            credentialProvider: .static(
                accessKeyId: config.accessKeyId,
                secretAccessKey: config.secretAccessKey
            ),
            httpClient: httpClient
        )
        self.httpClient = httpClient
        self.eventLoop = eventLoop
        self.client = client
        self.s3 = S3(client: client, region: .init(rawValue: config.region), endpoint: config.endpoint)
        self.bucket = config.bucket
    }

    func upload(body: HTTPBody, key: String, contentType: String) async throws {
        guard case .known(let length) = body.length, let byteCount = Int(exactly: length), byteCount >= 0 else {
            throw ServerError.badRequest("Object upload requires a known byte count")
        }
        try Task.checkCancellation()
        let request = S3.PutObjectRequest(
            body: .init(asyncSequence: EventLoopPacedBody(base: body, eventLoop: eventLoop), length: byteCount),
            bucket: bucket,
            contentType: contentType,
            key: key
        )
        _ = try await s3.putObject(request)
        try Task.checkCancellation()
    }

    func downloadBody(key: String) async throws -> HTTPBody {
        try Task.checkCancellation()
        let response = try await s3.getObject(.init(bucket: bucket, key: key))
        try Task.checkCancellation()
        return HTTPBody(
            response.body.map { ArraySlice($0.readableBytesView) },
            length: response.body.length.map { .known(Int64($0)) } ?? .unknown,
            iterationBehavior: .single
        )
    }

    func ensureBucketExists() async throws {
        do {
            _ = try await s3.headBucket(.init(bucket: bucket))
        } catch {
            _ = try await s3.createBucket(.init(bucket: bucket))
        }
    }

    func delete(key: String) async throws {
        let versioning = try await s3.getBucketVersioning(.init(bucket: bucket))
        guard versioning.status == nil else {
            // A delete marker is not payload erasure. Keep the cleanup record retryable
            // until a version-aware backend is configured instead of claiming success.
            throw ServerError.conflict("Artifact cleanup requires an unversioned bucket")
        }
        _ = try await s3.deleteObject(.init(bucket: bucket, key: key))
    }

    func keys(prefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await s3.listObjectsV2(.init(bucket: bucket, continuationToken: token, prefix: prefix))
            keys += (page.contents ?? []).compactMap(\.key)
            if page.isTruncated == true {
                guard let next = page.nextContinuationToken else { throw ServerError.internalServerError("Object listing ended early") }
                token = next
            } else {
                token = nil
            }
        } while token != nil
        return keys
    }

    func shutdown() async throws {
        try await client.shutdown()
        try await httpClient.shutdown()
    }
}
