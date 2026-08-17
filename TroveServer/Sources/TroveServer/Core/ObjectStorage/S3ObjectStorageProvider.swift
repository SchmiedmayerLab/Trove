//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SotoS3


final class S3ObjectStorageProvider: ObjectStorageProvider, @unchecked Sendable {
    private let client: AWSClient
    private let s3: S3
    private let bucket: String

    init(config: S3ObjectStorageConfiguration) {
        let client = AWSClient(
            credentialProvider: .static(
                accessKeyId: config.accessKeyId,
                secretAccessKey: config.secretAccessKey
            )
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

    func download(key: String) async throws -> Data {
        let response = try await s3.getObject(.init(bucket: bucket, key: key))
        var data = Data()
        for try await chunk in response.body {
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

    func shutdown() async throws {
        try await client.shutdown()
    }
}
