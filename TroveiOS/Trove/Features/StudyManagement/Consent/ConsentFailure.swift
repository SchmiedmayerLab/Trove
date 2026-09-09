//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


enum ConsentFailure: Error, Equatable, Sendable {
    case unavailable
    case invalidPresentation
    case incomplete
    case preparationFailed
    case pdfTooLarge
    case signInRequired
    case accessDenied
    case reviewRequired
    case outcomeUnknown
    case pendingOtherReview
    case historicalReceipt

    var message: LocalizedStringResource {
        switch self {
        case .unavailable: "Consent could not be loaded. Please try again."
        case .invalidPresentation: "This consent presentation cannot be safely displayed."
        case .incomplete: "Complete the required consent fields before submitting."
        case .preparationFailed: "Your consent document could not be prepared. Please try again."
        case .pdfTooLarge: "The consent document is too large to submit. Please contact the study team."
        case .signInRequired: "Sign in again to continue reviewing consent."
        case .accessDenied: "You cannot submit consent for this study at this time."
        case .reviewRequired: "Enrollment or consent has changed. Review the current status before submitting again."
        case .outcomeUnknown: "Submission could not be confirmed. Retry the same submission to check its result."
        case .pendingOtherReview: "Resolve the pending consent submission before opening another review."
        case .historicalReceipt: "Consent already exists, but its exact presentation cannot be verified here. Contact the study team."
        }
    }
}
