//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveProviderFHIR


/// A bounded provider page. Transport/conversion failures throw before any checkpoint can advance.
struct ProviderAcquisitionPage: Sendable {
    let records: [Data]
    let nextCursor: String?
    let complete: Bool
    /// Counts only source rows positively classified as outside requested scope or explicitly unsupported.
    let excludedRows: Int
}


struct ProviderAcquisitionRequest: Sendable {
    let registration: ProviderRegistration
    let sourceToken: String
    let window: Range<Date>
    let cursor: String?
    let acquiredAt: Date
    let queryAsOf: Date
    let conversionInstant: @Sendable (String, Data) async throws -> Date
    let demands: [ProviderDemand]
    let producer: ExchangeProducer
    let scope: ProviderConversionContext.Scope
}


/// Concrete provider clients must select consented elements before constructing FHIR records.
/// A catalog conversion descriptor alone does not qualify an upstream acquisition implementation.
protocol ProviderAcquisitionClient: Sendable {
    var provider: ConnectedProvider { get }
    var qualifiedSourceTokens: Set<String> { get }

    func fetch(_ request: ProviderAcquisitionRequest, credentials: ProviderCredentials) async throws -> ProviderAcquisitionPage
}
