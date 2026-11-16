//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import TroveAPIServer


private enum ClinicalRecordBundle {
    private struct Header: Decodable {
        struct Meta: Decodable { let profile: [String] }
        let meta: Meta
    }

    /// Graph validity and an exact commitment inventory precede any independent admission.
    static func records(_ submission: Components.Schemas.RecordBundleSubmission) throws -> [ExchangeRecord] {
        guard let bytes = Data(base64Encoded: submission.bundleBase64), !bytes.isEmpty,
              bytes.base64EncodedString() == submission.bundleBase64 else { throw ServerError.badRequest("Provide canonical Bundle base64") }
        guard bytes.count <= EventSubmissionLimits.maximumBundleBytes else { throw FHIRValidationClient.tooLarge }
        let records = try unpack(bytes)
        guard records.count == submission.records.count else { throw ServerError.badRequest("Record inventory does not match the Bundle") }
        var indexed: [BusinessIdentifier: ExchangeRecord] = [:]
        for record in records {
            guard indexed.updateValue(record, forKey: record.version.identifier.identifier) == nil else { throw FHIRValidationClient.invalid }
        }
        var requested: Set<BusinessIdentifier> = []
        return try submission.records.map { member in
            let value = member.commitment.producerEventIdentifier
            guard (1...512).contains(value.system.utf8.count), (1...512).contains(value.value.utf8.count),
                  let identifier = try? BusinessIdentifier(system: IdentifierSystem(value.system), value: value.value),
                  requested.insert(identifier).inserted, let record = indexed[identifier] else {
                throw ServerError.badRequest("Record inventory does not match the Bundle")
            }
            return record
        }
    }

    private static func unpack(_ bytes: Data) throws -> [ExchangeRecord] {
        do {
            let header = try JSONDecoder().decode(Header.self, from: bytes)
            let retraction = Profile.groveMobileRetractionBundle.value?.url.absoluteString ?? ""
            return try ExchangeGraph(validating: bytes, kind: header.meta.profile.contains(retraction) ? .retraction : .active).records()
        } catch {
            throw FHIRValidationClient.invalid
        }
    }

    static func restore(
        _ record: ExchangeRecord, member: Components.Schemas.RecordBundleMember, sourceID: UUID
    ) throws -> Components.Schemas.EventSubmission {
        do {
            guard (1...512).contains(member.entryFullUrls.count),
                  member.entryFullUrls.allSatisfy({ (1...512).contains($0.utf8.count) }) else { throw FHIRValidationClient.invalid }
            let restored = try ExchangeRecordBytes(record).restoring(entryFullURLs: member.entryFullUrls)
            let targets = try member.commitment.targets.map {
                EventTargetIntent.Target(consentID: try $0.consentId.requireId(), outputFullURLs: $0.outputFullUrls)
            }
            let commitment = try EventSubmissionCommitment(sourceID: sourceID, originalBytes: restored.json, targets: targets)
            guard commitment.payloadSHA256 == member.commitment.payloadSHA256 else { throw FHIRValidationClient.invalid }
            return .init(eventBase64: restored.json.base64EncodedString(), targets: member.commitment.targets)
        } catch {
            throw ServerError.badRequest("Record commitment does not match staged bytes")
        }
    }
}


extension ClinicalEventService {
    func acceptBundle(
        _ submission: Components.Schemas.RecordBundleSubmission, sourceID: UUID
    ) async throws -> [Components.Schemas.EventBatchResult] {
        _ = try AuthContext.checkIsParticipant()
        guard (1...EventSubmissionLimits.maximumBatchEvents).contains(submission.records.count) else {
            throw ServerError.badRequest("Submit between 1 and 16 record commitments")
        }
        guard submission.bundleBase64.utf8.count <= EventSubmissionLimits.maximumBundleBase64Bytes else { throw FHIRValidationClient.tooLarge }
        let source = try await SourceBindingService(database: database).find(id: sourceID)
        guard source.revokedAt == nil else { throw ServerError.conflict("Source binding is not active") }
        let records = try ClinicalRecordBundle.records(submission)
        var results: [Components.Schemas.EventBatchResult] = []
        for (member, record) in zip(submission.records, records) {
            try Task.checkCancellation()
            do {
                let original = try ClinicalRecordBundle.restore(record, member: member, sourceID: sourceID)
                let receipt = try await accept(submission: original, sourceID: sourceID)
                results.append(.EventReceipt(receipt.apiRepresentation))
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let status = (error as? ServerError)?.status.code ?? 500
                if status >= 500 {
                    database.logger.error("Clinical record failed", metadata: ["errorType": .string(String(reflecting: type(of: error)))])
                }
                results.append(.ProblemDetails(.init(
                    title: status >= 500 ? "Record Unavailable" : "Record Rejected",
                    status: status,
                    detail: status >= 500 ? "Retry the unchanged record" : "The record could not be admitted"
                )))
            }
        }
        try Task.checkCancellation()
        return results
    }
}
