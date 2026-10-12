//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


/// Projection consistency only; these synthetic values are not wire-format fixtures.
struct ClinicalRecordRevisionTests {
    struct Claim: Sendable {
        var record = "record"
        var writer = "writer"
        var version = "1"
        var output = "secondary"
    }

    @Test(arguments: [
        Claim(record: "other-record"),
        Claim(writer: "other-writer"),
        Claim(version: "2"),
        Claim(output: "primary")
    ], [false, true])
    func mixedRevisionOrDuplicateOutputIsRejected(claim: Claim, reversed: Bool) {
        let points = [Self.point(), Self.point(record: claim.record, writer: claim.writer, version: claim.version, output: claim.output)]
        #expect {
            try ClinicalRecordRevision(Self.event(reversed ? Array(points.reversed()) : points))
        } throws: { ($0 as? ServerError)?.status.code == 400 }
    }

    @Test(arguments: [(nil as String?, "1" as String?), ("writer" as String?, nil as String?)])
    func incompleteWriterPairIsRejected(claim: (String?, String?)) {
        #expect {
            try ClinicalRecordRevision(Self.event([Self.point(writer: claim.0, version: claim.1)]))
        } throws: { ($0 as? ServerError)?.status.code == 400 }
    }

    @Test
    func unorderedSingleRecordAndMaximumCanonicalVersionRemainSupported() throws {
        let unordered = try ClinicalRecordRevision(Self.event([Self.point(writer: nil, version: nil)]))
        #expect(unordered.writer == nil && unordered.version == nil)
        let maximum = String(repeating: "9", count: 4096)
        let ordered = try ClinicalRecordRevision(Self.event([Self.point(version: maximum)]))
        #expect(ordered.version == maximum)
    }
}


extension ClinicalRecordRevisionTests {
    private static func point(
        record: String = "record", writer: String? = "writer", version: String? = "1", output: String = "primary"
    ) -> ValidatedExchangeEvent.PointOutput {
        .init(
            fullURL: "urn:point:" + output,
            profile: CollectionRequirement.supportedProfile,
            effectiveAt: Date(),
            sourceRecordIdentifier: .init(system: "urn:record", value: record),
            sourceOutputIdentifier: .init(system: "urn:output", value: output),
            writerIdentifier: writer.map { .init(system: "urn:writer", value: $0) },
            writerVersion: version,
            quantityValue: "72",
            quantitySystem: "http://unitsofmeasure.org",
            quantityCode: "/min",
            codeSystem: "http://loinc.org",
            code: "8867-4"
        )
    }

    private static func event(_ outputs: [ValidatedExchangeEvent.PointOutput]) -> ValidatedExchangeEvent {
        .init(
            rawBytes: Data([1]),
            validatorIdentity: "synthetic-projection",
            eventIdentifierSystem: "urn:event",
            eventIdentifierValue: "1",
            producerInstance: UUID(),
            deploymentIdentifiers: .init(systems: [:]),
            participants: [],
            nodes: [],
            outputs: outputs
        )
    }
}
