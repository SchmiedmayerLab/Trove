//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Vapor


public struct S3ObjectStorageConfiguration: Sendable {
    public var endpoint: String
    public var accessKeyId: String
    public var secretAccessKey: String
    public var bucket: String
    public var region: String

    public init() {
        self.endpoint = Environment.ObjectStore.endpoint
        self.accessKeyId = Environment.ObjectStore.accessKey
        self.secretAccessKey = Environment.ObjectStore.secretKey
        self.bucket = Environment.ObjectStore.bucket
        self.region = Environment.ObjectStore.region
    }

    init(endpoint: String, accessKeyId: String, secretAccessKey: String, bucket: String, region: String) {
        self.endpoint = endpoint
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.bucket = bucket
        self.region = region
    }
}
