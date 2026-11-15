//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveSensorKit
import TroveAPIClient
import TroveHealthKit
import TroveSensorKit


enum HealthDataStatus: Equatable {
    case signedOut, notSetUp, ready, syncFinished, waiting, catchUpPending, blocked, revoked, notAuthorized, unavailable
    case documentReviewCancelled
    case permissionRequested, permissionNeeded, refreshNeeded, storageFull, historyUnavailable, sensorConfigurationRequired

    var message: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to manage health data collection."
        case .notSetUp: "Set up this device to share authorized health data with your enrolled studies."
        case .ready: "This device is set up. You can review data access and sync available data."
        case .syncFinished: "This sync pass finished. More data may be available; you can sync again."
        case .waiting: "Some data is waiting to be sent. Try syncing again later."
        case .catchUpPending: "This collection pass reached its limit. Keep the app open to continue."
        case .storageFull: "Local collection storage is full. Saved data has been preserved. Sync pending data or contact your study team."
        case .sensorConfigurationRequired: "This app build cannot collect all sensor data requested by your studies. Contact your study team."
        case .historyUnavailable: "Earlier sensor data could not be reproduced exactly. Saved data has been preserved. Contact your study team."
        case .blocked: "Some data could not be processed safely. Your saved data has been preserved. Contact your study team."
        case .revoked: "One of this device’s data sources has been revoked. Contact your study team."
        case .notAuthorized: "An active study consent for health data collection is required. Review your studies before continuing."
        case .unavailable: "Health data sync is unavailable. Check your connection and try again."
        case .refreshNeeded: "Study collection settings changed. Collection will resume with the latest settings."
        case .documentReviewCancelled: "Document review was canceled. Saved data has been preserved. You can review documents again."
        case .permissionRequested: "The data access request finished. You can review permissions in Health and Settings."
        case .permissionNeeded: "Review data access before syncing data from this device."
        }
    }

    init(error: any Error) {
        switch error {
        case GroveSensorKit.SensorKit.BatchReplayError.batchUnavailable,
             GroveSensorKit.SensorKit.BatchReplayError.deviceUnavailable,
             GroveSensorKit.SensorKit.QueryAnchorAcknowledgementError.pendingBatchMismatch: self = .historyUnavailable
        case SensorKitAcquisition.AcquisitionError.retryMismatch, SensorKitAcquisition.AcquisitionError.invalidBatch,
             SensorKitAcquisition.AcquisitionError.conversionRefused: self = .blocked
        case ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized: self = .notAuthorized
        case EventDeliveryJournal.JournalError.sourceRevoked: self = .revoked
        case EventDeliveryJournal.JournalError.staleCheckpoint, EventDeliveryJournal.JournalError.staleCollectionState: self = .refreshNeeded
        case EventDeliveryJournal.JournalError.capacityExceeded: self = .storageFull
        case is EventDeliveryJournal.JournalError, is CocoaError: self = .blocked
        case HealthKitAcquisition.AcquisitionError.unsupportedDelta,
             HealthKitAcquisition.AcquisitionError.invalidQueryDefinition: self = .blocked
        default: self = .unavailable
        }
    }
}
