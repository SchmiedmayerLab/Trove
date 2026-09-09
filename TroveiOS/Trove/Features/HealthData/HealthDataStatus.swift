//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIClient
import TroveHealthKit


enum HealthDataStatus: Equatable {
    case signedOut, notSetUp, ready, syncFinished, waiting, catchUpPending, blocked, revoked, notAuthorized, unavailable
    case permissionRequested, permissionNeeded

    var message: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to manage health data collection."
        case .notSetUp: "Set up this device to share heart rate data with your enrolled studies."
        case .ready: "This device is set up. You can review Health access and sync available data."
        case .syncFinished: "This sync pass finished. More data may be available; you can sync again."
        case .waiting: "Some data is waiting to be sent. Try syncing again later."
        case .catchUpPending: "This collection pass reached its limit. Keep the app open to continue."
        case .blocked: "Some data could not be processed safely. Your saved data has been preserved. Contact your study team."
        case .revoked: "Collection from this device has been revoked. Contact your study team."
        case .notAuthorized: "An active study consent for heart rate collection is required. Review your studies before continuing."
        case .unavailable: "Health data sync is unavailable. Check your connection and try again."
        case .permissionRequested: "The Health access request finished. You can review permissions in Health."
        case .permissionNeeded: "Review Health access before syncing data from this device."
        }
    }

    init(error: any Error) {
        switch error {
        case ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized: self = .notAuthorized
        case EventDeliveryJournal.JournalError.sourceRevoked: self = .revoked
        case is EventDeliveryJournal.JournalError, is CocoaError: self = .blocked
        case HeartRateAcquisition.AcquisitionError.unsupportedDelta,
             HeartRateAcquisition.AcquisitionError.invalidQueryDefinition: self = .blocked
        default: self = .unavailable
        }
    }
}
