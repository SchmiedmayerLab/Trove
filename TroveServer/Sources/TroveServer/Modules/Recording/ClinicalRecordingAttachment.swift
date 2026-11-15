//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4
import TroveAPITypes


/// Exact storage and decoded-content evidence carried into the clinical custody transaction.
struct ClinicalRecordingAttachment: Sendable {
    let reference: ArtifactReference
    let declaration: RecordingTransferDeclaration
    let content: RecordingContentVerification

    static func validate(document: DocumentReference, declaration: RecordingTransferDeclaration) throws {
        let source = try FHIRSourceTypeEvidence.extract(document.extension ?? [])
        if let declaredSource = declaration.output.sourceTypeIdentifier {
            guard source?.identifier == declaredSource else { throw FHIRValidationClient.invalid }
        } else {
            guard declaration.output.isWorkoutRoute else { throw FHIRValidationClient.invalid }
        }
        guard document.meta?.profile?.contains(where: { $0.value?.url.absoluteString == declaration.output.profile }) == true,
              document.content.count == 1, let content = document.content.first,
              content.format?.system?.value?.url.absoluteString == FHIRRecordingProjection.formatSystem,
              content.format?.code?.value?.string == declaration.output.code,
              content.attachment.url?.value?.url.absoluteString == declaration.attachmentPath,
              content.attachment.data == nil,
              let size = content.attachment.size?.value?.integer, Int(size) == declaration.content.sourceByteCount,
              let hash = content.attachment.hash?.value?.data(), hash.count == 20 else { throw FHIRValidationClient.invalid }
    }

    func validate(document: DocumentReference, bounds: ClinicalMeasurementBounds) throws {
        try Self.validate(document: document, declaration: declaration)
        guard document.content.first?.attachment.hash?.value?.data() == content.attachmentSHA1,
              bounds == declaration.output.measurementBounds else { throw FHIRValidationClient.invalid }
    }
}
