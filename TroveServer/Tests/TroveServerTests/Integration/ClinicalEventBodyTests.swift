//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import Testing
@testable import TroveServer


struct ClinicalEventBodyTests {
    private static var forbiddenValidator: FHIRValidationClient {
        FHIRValidationClient(expectedIdentity: "sha256:" + String(repeating: "a", count: 64)) { _ in
            Issue.record("Incomplete request must not reach validation")
            return (200, Data())
        }
    }

    @Test(arguments: [0, 8])
    func interruptedUploadIsRetryableWithoutValidationOrStorage(prefixSize: Int) async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let stream = AsyncThrowingStream<HTTPBody.ByteChunk, any Error> { continuation in
                continuation.yield(ArraySlice(repeating: 32, count: prefixSize))
                continuation.finish(throwing: URLError(.networkConnectionLost))
            }
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = ClinicalEventService(database: app.db, validator: Self.forbiddenValidator)
                await #expect {
                    try await service.accept(
                        body: HTTPBody(stream, length: .unknown), sourceID: fixture.source.id, targets: fixture.targets
                    )
                } throws: { ($0 as? TroveServer.ServerError)?.status.code == 503 }
                try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }

    @Test
    func oversizedUploadIsNotValidatedOrStored() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let body = HTTPBody(Data(), length: .known(Int64(FHIRValidationClient.maximumBytes + 1)))
                let service = ClinicalEventService(database: app.db, validator: Self.forbiddenValidator)
                await #expect {
                    try await service.accept(body: body, sourceID: fixture.source.id, targets: fixture.targets)
                } throws: { ($0 as? TroveServer.ServerError)?.status.code == 413 }
                try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }

    @Test
    func declaredTruncationIsRetryableWithoutValidationOrStorage() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let body = HTTPBody([1], length: .known(2))
                let service = ClinicalEventService(database: app.db, validator: Self.forbiddenValidator)
                await #expect {
                    try await service.accept(body: body, sourceID: fixture.source.id, targets: fixture.targets)
                } throws: { ($0 as? TroveServer.ServerError)?.status.code == 503 }
                try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }

    @Test
    func cancelledReadIsNotValidatedOrStored() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await ClinicalEventStoreTests.prepare(on: app)
            let stream = AsyncThrowingStream<HTTPBody.ByteChunk, any Error> { continuation in
                continuation.yield([1])
                continuation.finish(throwing: CancellationError())
            }
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let service = ClinicalEventService(database: app.db, validator: Self.forbiddenValidator)
                await #expect(throws: CancellationError.self) {
                    try await service.accept(
                        body: HTTPBody(stream, length: .unknown), sourceID: fixture.source.id, targets: fixture.targets
                    )
                }
                try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
            }
        }
    }
}
