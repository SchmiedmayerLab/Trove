//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import ModelsR4
import OpenAPIRuntime
import Testing
import TroveAPITypes
@testable import TroveServer


struct FHIRClinicalDocumentTests {
    static let fixtures = ["clinical-record-1.0.2", "clinical-record-4.0.1", "cda-document"]

    @Test(arguments: fixtures)
    func exactNativeDocumentUsesItsSourceClock(_ fixture: String) async throws {
        let input = try Fixture(fixture)
        let attachment = try await input.attachment()
        let event = try FHIRPointProjection.project(
            validatedBytes: input.bytes, validatorIdentity: "synthetic-receiver", recordings: [attachment]
        )
        let output = try #require(event.outputs.first)
        #expect(event.outputs.count == 1 && output.value == .recording)
        #expect(output.measurementBounds == input.bounds)
        #expect(output.sourceRepositoryKind == .healthKit)
        #expect(input.document.context?.period == nil)
        #expect(output.effectiveAt != (try input.document.date?.value?.asNSDate()))
        #expect(attachment.content.attachmentSHA1 == Data(Insecure.SHA1.hash(data: input.payload)))
        let media = try StudyRecordingMedia(event: event, outputFullURL: input.address)
        #expect(media.contentType.rawValue == input.document.content.first?.attachment.contentType?.value?.string)
        let projected = try StudyPointProjection.project(
            event, outputs: [output.fullURL], subject: .init(system: IdentifierSystem("https://example.test/study-subject"), value: "synthetic")
        )
        let graph = try JSONDecoder().decode(ModelsR4.Bundle.self, from: projected.json)
        let (_, resources) = try FHIRPointProjection.index(#require(graph.entry))
        let derived = try #require(resources.first { $0.value.resourceType == "DocumentReference" })
        let document = try #require(derived.value.get() as? DocumentReference)
        #expect(document.content == input.document.content)
        let entities = resources.values.flatMap { resource -> [ProvenanceEntity] in
            guard case .provenance(let provenance) = resource else {
                return []
            }
            return provenance.entity ?? []
        }
        let basis: CollectionTimeBasis = fixture == "cda-document" ? .cdaSourceDocumentPeriod : .clinicalRecordDownload
        #expect(try HealthKitDocumentSelectionTime(entities: entities, expectedBasis: basis).period == input.period)
    }

    @Test(arguments: fixtures)
    func clinicalCarePeriodDoesNotReplaceSourceSelectionClock(_ fixture: String) async throws {
        let input = try Fixture(fixture)
        var document = input.document
        document.context = DocumentReferenceContext(period: try JSONDecoder().decode(Period.self, from: Data(
            #"{"start":"2001-01-01T00:00:00Z","end":"2001-01-02T00:00:00Z"}"#.utf8
        )))
        let period = try FHIRRecordingSourcePeriod.period(document, fullURL: input.address, resources: input.resources)
        let attachment = try await input.attachment()
        let facts = try FHIRRecordingProjection.project(document, external: attachment, selectionPeriod: period)
        #expect(facts.bounds == input.bounds)
    }

    @Test(arguments: ["missing", "duplicate", "wrong-basis", "date-only", "no-zone", "wrong-record", "wrong-role", "wrong-target"])
    func refusesUnboundSourceClocks(_ corruption: String) throws {
        let input = try Fixture("clinical-record-4.0.1")
        #expect(throws: (any Error).self) {
            var resources = input.resources
            let address = try #require(resources.first { $0.value.resourceType == "Provenance" }?.key)
            var provenance = try #require(resources[address]?.get() as? Provenance)
            var entity = try #require(provenance.entity?.first)
            let index = try #require(entity.extension?.firstIndex { $0.url == HealthKitSourceDocumentTime.extensionURL })
            var extensions = try #require(entity.extension)
            switch corruption {
            case "missing": extensions.remove(at: index)
            case "duplicate": extensions.append(extensions[index])
            case "wrong-basis":
                extensions[index].extension?[0].value = .code(FHIRPrimitive(FHIRString(CollectionTimeBasis.cdaSourceDocumentPeriod.rawValue)))
            case "date-only", "no-zone":
                let time = corruption == "date-only" ? "2026-08-17" : "2026-08-17T15:30:00"
                extensions[index].extension?[1].value = .period(try JSONDecoder().decode(
                    Period.self, from: JSONSerialization.data(withJSONObject: ["start": time, "end": time])
                ))
            case "wrong-record":
                let identifier = try #require(entity.what.identifier)
                entity.what = Reference(identifier: Identifier(system: identifier.system, type: identifier.type, value: "different-source-record"))
            case "wrong-role": entity.role = FHIRPrimitive(.revision)
            case "wrong-target":
                provenance.target = [Reference(reference: FHIRPrimitive(FHIRString("urn:uuid:00000000-0000-4000-8000-000000000000")))]
            default: Issue.record("Unknown corruption")
            }
            entity.extension = extensions
            provenance.entity = [entity]
            resources[address] = .provenance(provenance)
            _ = try FHIRRecordingSourcePeriod.period(input.document, fullURL: input.address, resources: resources)
        }
    }
}


extension FHIRClinicalDocumentTests {
    private struct Fixture {
        let bytes: Data
        let payload: Data
        let document: DocumentReference
        let address: String
        let resources: [String: ResourceProxy]
        let period: Period
        let bounds: ClinicalMeasurementBounds

        init(_ name: String) throws {
            let directory = try #require(Bundle.module.url(forResource: "HealthKitClinicalDocuments", withExtension: nil))
                .appendingPathComponent(name)
            bytes = try Data(contentsOf: directory.appendingPathComponent("bundle.json"))
            let graph = try ExchangeGraph(validating: bytes, kind: .active)
            let (_, indexed) = try FHIRPointProjection.index(#require(graph.bundle.entry))
            resources = indexed
            let entry = try #require(indexed.first { $0.value.resourceType == "DocumentReference" })
            address = entry.key
            document = try #require(entry.value.get() as? DocumentReference)
            let path = try #require(document.content.first?.attachment.url?.value?.url.relativeString)
            payload = try Data(contentsOf: directory.appendingPathComponent(path))
            period = try #require(try FHIRRecordingSourcePeriod.period(document, fullURL: address, resources: indexed))
            bounds = try .init(
                start: FHIRMeasurementInstant.exact(#require(period.start?.value)),
                end: FHIRMeasurementInstant.exact(#require(period.end?.value))
            )
        }

        func attachment() async throws -> ClinicalRecordingAttachment {
            let content = try #require(document.content.first), digest = ArtifactStore.digest(payload)
            let code = try #require(content.format?.code?.value?.string)
            let format = try #require(RegisteredRecordingFormat(rawValue: code))
            let profile = format == .fhirResource ? Profile.healthkitClinicalRecordDocument : Profile.healthkitRecordingDocument
            let source = try #require(try FHIRSourceTypeEvidence.extract(document.extension ?? []))
            let declaration = try RecordingTransferDeclaration(
                attachmentPath: #require(content.attachment.url?.value?.url.relativeString),
                outputFullURL: address,
                profile: #require(profile.value?.url.absoluteString),
                format: format,
                effectiveAt: bounds.startDate,
                effectiveEnd: #require(bounds.endDate),
                content: .init(
                    storedByteCount: payload.count,
                    storedSHA256: digest,
                    sourceByteCount: payload.count,
                    sourceSHA256: digest,
                    encoding: .identity
                ),
                targets: [.init(consentID: UUID(), outputFullURLs: [address])],
                sourceTypeIdentifier: source.identifier
            )
            let verified = try await RecordingContentVerification.verify(
                HTTPBody(payload), declaration: declaration, maximumWindowByteCount: 8 * 1024 * 1024
            )
            let owner = UUID()
            return .init(
                reference: .init(
                    id: UUID(),
                    ownerID: owner,
                    purpose: .recording,
                    digest: digest,
                    byteCount: payload.count,
                    scope: .participantSource(.init(participantID: owner, sourceBindingID: UUID()))
                ),
                declaration: declaration,
                content: verified
            )
        }
    }
}
