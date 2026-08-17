//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Testing
import TroveAPIClient
import TroveAPIServer
import TroveAPITypes


/// Compile-time guards that the generated files exist and expose the expected types.
/// If any generated file is deleted or empty, this file will fail to compile.
@Test
func generatedTypesExist() {
    _ = (any APIProtocol).self  // Types.swift
    _ = Client.self             // Client.swift
    _ = Client.registerHandlers // Server.swift
}
