//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import JWTKit


struct KeycloakJWTPayload: JWTPayload {
    var sub: SubjectClaim
    var exp: ExpirationClaim
    var email: String
    var roles: [String]
    var groups: [String]? // swiftlint:disable:this discouraged_optional_collection

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}
