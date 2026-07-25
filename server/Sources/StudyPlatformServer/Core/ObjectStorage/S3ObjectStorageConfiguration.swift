//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
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
}
