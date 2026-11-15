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


struct ProviderTransportRetryTests {
    @Test
    func retryAfterRetainsOnlyAValidatedDelay() throws {
        let now = Date(timeIntervalSince1970: 0)
        #expect(ProviderTransportRetry.parse("120", now: now).notBefore == now.addingTimeInterval(120))
        #expect(ProviderTransportRetry.parse("Thu, 01 Jan 1970 00:02:00 GMT", now: now).notBefore == now.addingTimeInterval(120))
        #expect(ProviderTransportRetry.parse("-1", now: now).notBefore == now.addingTimeInterval(3600))
        #expect(ProviderTransportRetry.parse("nonsensical-provider-detail", now: now).notBefore == now.addingTimeInterval(3600))
        #expect(ProviderTransportRetry.parse(nil, now: now).notBefore == now.addingTimeInterval(3600))
        #expect(ProviderTransportRetry.parse("999999999999999999999999999999", now: now).notBefore == .distantFuture)
    }
}
