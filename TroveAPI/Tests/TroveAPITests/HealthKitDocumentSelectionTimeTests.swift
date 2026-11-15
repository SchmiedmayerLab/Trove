// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import GroveFHIRContract
import ModelsR4
import Testing
import TroveAPITypes


struct HealthKitDocumentSelectionTimeTests {
    private func entity(start: String = "2024-01-01T12:00:00.123Z", end: String = "2024-01-01T12:00:00.124Z") throws -> ProvenanceEntity {
        entity(start: try DateTime(start), end: try DateTime(end))
    }

    private func entity(start: DateTime, end: DateTime) -> ProvenanceEntity {
        ProvenanceEntity(
            extension: [
                Extension(
                extension: [
                    Extension(url: "basis", value: .code("clinical-record-download")),
                    Extension(url: "period", value: .period(Period(end: FHIRPrimitive(end), start: FHIRPrimitive(start))))
                ],
                url: HealthKitSourceDocumentTime.extensionURL
                )
            ],
            role: FHIRPrimitive(.source),
            what: Reference(identifier: Identifier(system: "urn:example:source", value: "source"))
        )
    }

    @Test
    func sourcePeriodPreservesTheOriginalFHIRBoundsAndRequiresItsExactBasis() throws {
        let source = try entity()
        let value = try HealthKitDocumentSelectionTime(entities: [source], expectedBasis: .clinicalRecordDownload)
        #expect(value.basis == .clinicalRecordDownload)
        #expect(value.period.start?.value?.description == "2024-01-01T12:00:00.123Z")
        #expect(value.start < value.end)
        #expect(throws: HealthKitDocumentSelectionTime.Failure.self) {
            try HealthKitDocumentSelectionTime(entities: [source], expectedBasis: .cdaSourceDocumentPeriod)
        }
    }

    @Test(arguments: ["2024-01-01", "2024-01-02T12:00:00Z"])
    func incompleteOrReversedSourceBoundsAreNeverInferred(start: String) throws {
        let source = try entity(start: start)
        #expect(throws: HealthKitDocumentSelectionTime.Failure.self) {
            try HealthKitDocumentSelectionTime(entities: [source], expectedBasis: .clinicalRecordDownload)
        }
    }

    @Test
    func sourceBoundWithoutATimeZoneIsNeverInferred() throws {
        // The FHIR parser refuses a time without a zone, so this bound can only be constructed directly.
        let start = DateTime(date: FHIRDate(year: 2024, month: 1, day: 1), time: FHIRTime(hour: 12, minute: 0, second: 0))
        let source = entity(start: start, end: try DateTime("2024-01-01T12:00:00.124Z"))
        #expect(throws: HealthKitDocumentSelectionTime.Failure.self) {
            try HealthKitDocumentSelectionTime(entities: [source], expectedBasis: .clinicalRecordDownload)
        }
    }

    @Test(arguments: ["modifier", "nested-basis", "nested-period", "duplicate", "wrong-role"])
    func unrecognizedOrAmbiguousSourceMeaningIsRefused(mode: String) throws {
        var source = try entity()
        switch mode {
        case "modifier": source.modifierExtension = [Extension(url: "urn:example:modifier", value: .boolean(true))]
        case "nested-basis": source.extension?[0].extension?[0].extension = [Extension(url: "urn:example:nested", value: .boolean(true))]
        case "nested-period": source.extension?[0].extension?[1].extension = [Extension(url: "urn:example:nested", value: .boolean(true))]
        case "wrong-role": source.role = FHIRPrimitive(.derivation)
        default: break
        }
        #expect(throws: HealthKitDocumentSelectionTime.Failure.self) {
            try HealthKitDocumentSelectionTime(entities: mode == "duplicate" ? [source, source] : [source], expectedBasis: .clinicalRecordDownload)
        }
    }
}
