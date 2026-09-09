//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SotoS3
import Vapor


final class S3ObjectStorageProvider: ObjectStorageProvider, Sendable {
    private let client: AWSClient
    private let s3: S3
    private let bucket: String

    init(application: Application, config: S3ObjectStorageConfiguration) throws {
        try application.outboundTransport.validateEndpoint(config.endpoint)
        let client = AWSClient(
            credentialProvider: .static(
                accessKeyId: config.accessKeyId,
                secretAccessKey: config.secretAccessKey
            ),
            httpClient: application.http.client.shared
        )
        self.client = client
        self.s3 = S3(client: client, region: .init(rawValue: config.region), endpoint: config.endpoint)
        self.bucket = config.bucket
    }

    func upload(data: Data, key: String, contentType: String) async throws {
        let request = S3.PutObjectRequest(
            body: .init(bytes: data),
            bucket: bucket,
            contentType: contentType,
            key: key
        )
        _ = try await s3.putObject(request)
    }

    func download(key: String, maximumBytes: Int) async throws -> Data {
        let response = try await s3.getObject(.init(bucket: bucket, key: key))
        var data = Data()
        for try await chunk in response.body {
            guard chunk.readableBytes <= maximumBytes - data.count else {
                throw ServerError.internalServerError("Stored object exceeds the read limit")
            }
            data.append(contentsOf: chunk.readableBytesView)
        }
        return data
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

    func shutdown() async throws {
        try await client.shutdown()
    }
}
