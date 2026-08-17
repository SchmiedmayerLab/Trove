//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import Trove


struct TroveAPIModuleTests {
    /// The client is only built in `configure()`. Before that runs callers must get an error
    /// rather than a crash, which is what the implicitly unwrapped optional used to give them.
    @Test
    func requireClientThrowsBeforeConfigure() throws {
        let module = TroveAPIModule()

        #expect(module.client == nil)

        var thrown: (any Error)?
        #expect(throws: TroveAccountError.self) {
            do {
                _ = try module.requireClient()
            } catch {
                thrown = error
                throw error
            }
        }
        guard case .clientUnavailable? = thrown as? TroveAccountError else {
            Issue.record("expected clientUnavailable, got \(String(describing: thrown))")
            return
        }
    }
}


struct ConfigTests {
    /// The redirect URI is assembled from the scheme, so a malformed scheme previously
    /// crashed on a force unwrap.
    @Test
    func redirectURIIsWellFormed() {
        let uri = Config.keycloakRedirectURI

        #expect(uri.scheme == Config.keycloakRedirectScheme)
        #expect(uri.host == "callback")
    }

    @Test
    func endpointsAreAbsolute() {
        #expect(Config.apiBaseURL.scheme?.hasPrefix("http") == true)
        #expect(Config.keycloakIssuer.scheme?.hasPrefix("http") == true)
        #expect(!Config.keycloakClientID.isEmpty)
    }
}


struct ISO8601DateTests {
    @Test
    func roundTripsADate() throws {
        let parsed = try #require(Date(iso8601DateString: "2026-08-17"))

        #expect(parsed.iso8601DateString == "2026-08-17")
    }

    /// The formatter pins UTC and the POSIX locale, so the rendered day must not shift with
    /// the machine's time zone.
    @Test
    func usesAStableCalendarAndTimeZone() {
        let formatter = Date.iso8601DateFormatter

        #expect(formatter.timeZone == TimeZone(identifier: "UTC"))
        #expect(formatter.locale == Locale(identifier: "en_US_POSIX"))
        #expect(formatter.dateFormat == "yyyy-MM-dd")
    }

    @Test
    func rejectsMalformedInput() {
        #expect(Date(iso8601DateString: "17-08-2026") == nil)
        #expect(Date(iso8601DateString: "not a date") == nil)
    }
}
