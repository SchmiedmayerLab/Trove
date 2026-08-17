//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent


extension SchemaBuilder {
    @discardableResult
    func timestamps() -> Self {
        field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
    }
}
