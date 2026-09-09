//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//


/// The account-scoped specialization of the client's durable query and custody journal.
public typealias EventDeliveryJournal = DeliveryJournal<TroveDeliveryContract>
