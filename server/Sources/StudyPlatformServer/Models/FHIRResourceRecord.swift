//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import ModelsR4


struct FHIRPayload: Codable, @unchecked Sendable {
    let proxy: ResourceProxy

    init(_ proxy: ResourceProxy) {
        self.proxy = proxy
    }

    init(from decoder: any Decoder) throws {
        self.proxy = try ResourceProxy(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try proxy.encode(to: encoder)
    }
}


final class FHIRResourceRecord: Model, @unchecked Sendable {
    final class IDValue: Fields, Hashable, @unchecked Sendable {
        @Field(key: "participant_id") var participantID: UUID
        @Field(key: "time") var time: Date
        @Field(key: "external_id") var externalID: String

        init() {}

        init(participantID: UUID, time: Date, externalID: String) {
            self.participantID = participantID
            self.time = time
            self.externalID = externalID
        }

        static func == (lhs: IDValue, rhs: IDValue) -> Bool {
            lhs.participantID == rhs.participantID
                && lhs.time == rhs.time
                && lhs.externalID == rhs.externalID
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(participantID)
            hasher.combine(time)
            hasher.combine(externalID)
        }
    }

    static let schema = "fhir_resources"

    @CompositeID var id: IDValue?
    @Field(key: "resource_type") var resourceType: String
    @OptionalField(key: "code") var code: String?
    @OptionalField(key: "code_system") var codeSystem: String?
    @OptionalField(key: "value") var value: Double?
    @OptionalField(key: "value_code") var valueCode: String?
    @OptionalField(key: "value_system") var valueSystem: String?
    @Field(key: "resource") var resource: FHIRPayload

    init() {}

    init(
        participantID: UUID,
        resourceType: String,
        time: Date,
        externalID: String,
        resource: ResourceProxy,
        code: String? = nil,
        codeSystem: String? = nil,
        value: Double? = nil,
        valueCode: String? = nil,
        valueSystem: String? = nil
    ) {
        self.id = .init(participantID: participantID, time: time, externalID: externalID)
        self.resourceType = resourceType
        self.code = code
        self.codeSystem = codeSystem
        self.value = value
        self.valueCode = valueCode
        self.valueSystem = valueSystem
        self.resource = FHIRPayload(resource)
    }
}
