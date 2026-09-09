//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import JWTKit


struct KeycloakJWTPayload: JWTPayload {
    var iss: IssuerClaim
    var aud: KeycloakAudience
    var sub: SubjectClaim
    var exp: ExpirationClaim
    var nbf: NotBeforeClaim?
    var email: String
    var roles: [String]
    var groups: [String]? // swiftlint:disable:this discouraged_optional_collection

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
        try nbf?.verifyNotBefore()
    }
}
