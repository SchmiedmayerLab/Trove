//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
@testable import TroveServer


// Production callers state whether a study receives device unit identifiers. Tests unrelated to that rule use
// these overloads, which withhold them as a study does by default.

extension PublishedCollectionPolicy {
    static func compile(
        studyID: UUID, revision: Int, requirements: [CollectionRequirement], enrollmentPeriod: EnrollmentPeriod = .ongoing
    ) throws -> Self {
        try compile(
            studyID: studyID, revision: revision, requirements: requirements, receivesDeviceUnitIdentifiers: false, enrollmentPeriod: enrollmentPeriod
        )
    }
}


extension StudyPointProjection {
    static func project(
        _ event: ValidatedExchangeEvent,
        outputs: Set<String>,
        subject: BusinessIdentifier,
        id: UUID = UUID(),
        recordingURLs: [String: String] = [:],
        maximumBytes: Int = StudyExportLimits.standard.bundleBytes
    ) throws -> Result {
        try project(
            event,
            outputs: outputs,
            subject: subject,
            receivesDeviceUnitIdentifiers: false,
            id: id,
            recordingURLs: recordingURLs,
            maximumBytes: maximumBytes
        )
    }
}


extension StudyPointExport {
    static func build(
        _ event: ValidatedExchangeEvent,
        grants: [Grant],
        context: Context,
        id: UUID = UUID(),
        recordingURLs: [String: String] = [:],
        maximumBytes: Int = StudyExportLimits.standard.bundleBytes
    ) throws -> Result {
        try build(
            event,
            grants: grants,
            context: context,
            receivesDeviceUnitIdentifiers: false,
            id: id,
            recordingURLs: recordingURLs,
            maximumBytes: maximumBytes
        )
    }
}
