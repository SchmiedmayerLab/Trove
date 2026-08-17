//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveStudyDefinition
import Testing
import TroveAPIServer
@testable import TroveServer


@Suite
struct ParticipationCriterionMapperTests {
    // MARK: - Domain → Schema

    @Test
    func mapsAgeAtLeastToSchema() throws {
        let schema = try Components.Schemas.ParticipationCriterion(.ageAtLeast(18))

        guard case .ageAtLeast(let value) = schema else {
            Issue.record("Expected ageAtLeast, got \(schema)")
            return
        }
        #expect(value.age == 18)
    }

    @Test
    func mapsIsFromRegionToSchema() throws {
        let schema = try Components.Schemas.ParticipationCriterion(.isFromRegion(Locale.Region("US")))

        guard case .isFromRegion(let value) = schema else {
            Issue.record("Expected isFromRegion, got \(schema)")
            return
        }
        #expect(value.region == "US")
    }

    @Test
    func mapsSpeaksLanguageToSchema() throws {
        let schema = try Components.Schemas.ParticipationCriterion(.speaksLanguage(Locale.Language(identifier: "de")))

        guard case .speaksLanguage(let value) = schema else {
            Issue.record("Expected speaksLanguage, got \(schema)")
            return
        }
        #expect(value.language == "de")
    }

    @Test
    func mapsNotToSchema() throws {
        let schema = try Components.Schemas.ParticipationCriterion(.not(.ageAtLeast(65)))

        guard case .not(let value) = schema else {
            Issue.record("Expected not, got \(schema)")
            return
        }
        guard case .ageAtLeast(let inner) = value.criterion else {
            Issue.record("Expected inner ageAtLeast, got \(value.criterion)")
            return
        }
        #expect(inner.age == 65)
    }

    @Test
    func mapsAllToSchema() throws {
        let schema = try Components.Schemas.ParticipationCriterion(.all([.ageAtLeast(18), .isFromRegion(Locale.Region("DE"))]))

        guard case .all(let value) = schema else {
            Issue.record("Expected all, got \(schema)")
            return
        }
        #expect(value.criteria.count == 2)
    }

    @Test
    func mapsAnyToSchema() throws {
        let schema = try Components.Schemas.ParticipationCriterion(.any([.isFromRegion(Locale.Region("US")), .isFromRegion(Locale.Region("DE"))]))

        guard case .any(let value) = schema else {
            Issue.record("Expected any, got \(schema)")
            return
        }
        #expect(value.criteria.count == 2)
    }

    // MARK: - Schema → Domain

    @Test
    func mapsAgeAtLeastToDomain() {
        let schema: Components.Schemas.ParticipationCriterion = .ageAtLeast(.init(_type: .ageAtLeast, age: 21))
        let model = StudyDefinition.ParticipationCriterion(schema)

        guard case .ageAtLeast(let age) = model else {
            Issue.record("Expected ageAtLeast, got \(model)")
            return
        }
        #expect(age == 21)
    }

    @Test
    func mapsIsFromRegionToDomain() {
        let schema: Components.Schemas.ParticipationCriterion = .isFromRegion(.init(_type: .isFromRegion, region: "DE"))
        let model = StudyDefinition.ParticipationCriterion(schema)

        guard case .isFromRegion(let region) = model else {
            Issue.record("Expected isFromRegion, got \(model)")
            return
        }
        #expect(region.identifier == "DE")
    }

    @Test
    func mapsSpeaksLanguageToDomain() {
        let schema: Components.Schemas.ParticipationCriterion = .speaksLanguage(.init(_type: .speaksLanguage, language: "en"))
        let model = StudyDefinition.ParticipationCriterion(schema)

        guard case .speaksLanguage(let language) = model else {
            Issue.record("Expected speaksLanguage, got \(model)")
            return
        }
        #expect(language.minimalIdentifier == "en")
    }

    @Test
    func mapsNotToDomain() {
        let schema: Components.Schemas.ParticipationCriterion = .not(
            .init(_type: .not, criterion: .ageAtLeast(.init(_type: .ageAtLeast, age: 65)))
        )
        let model = StudyDefinition.ParticipationCriterion(schema)

        guard case .not(let inner) = model, case .ageAtLeast(let age) = inner else {
            Issue.record("Expected not(ageAtLeast), got \(model)")
            return
        }
        #expect(age == 65)
    }

    @Test
    func mapsAllToDomain() {
        let schema: Components.Schemas.ParticipationCriterion = .all(
            .init(_type: .all, criteria: [
                .ageAtLeast(.init(_type: .ageAtLeast, age: 18)),
                .isFromRegion(.init(_type: .isFromRegion, region: "US"))
            ])
        )
        let model = StudyDefinition.ParticipationCriterion(schema)

        guard case .all(let criteria) = model else {
            Issue.record("Expected all, got \(model)")
            return
        }
        #expect(criteria.count == 2)
    }

    @Test
    func mapsAnyToDomain() {
        let schema: Components.Schemas.ParticipationCriterion = .any(
            .init(_type: .any, criteria: [
                .isFromRegion(.init(_type: .isFromRegion, region: "US")),
                .isFromRegion(.init(_type: .isFromRegion, region: "DE"))
            ])
        )
        let model = StudyDefinition.ParticipationCriterion(schema)

        guard case .any(let criteria) = model else {
            Issue.record("Expected any, got \(model)")
            return
        }
        #expect(criteria.count == 2)
    }

    // MARK: - Round-Trip

    @Test
    func roundTripComplexCriterion() throws {
        let original: StudyDefinition.ParticipationCriterion = .all([
            .ageAtLeast(18),
            .any([
                .isFromRegion(Locale.Region("US")),
                .isFromRegion(Locale.Region("DE"))
            ]),
            .not(.ageAtLeast(65)),
            .speaksLanguage(Locale.Language(identifier: "en"))
        ])

        let schema = try Components.Schemas.ParticipationCriterion(original)
        let roundTripped = StudyDefinition.ParticipationCriterion(schema)

        guard case .all(let criteria) = roundTripped else {
            Issue.record("Expected all, got \(roundTripped)")
            return
        }

        #expect(criteria.count == 4)

        guard case .ageAtLeast(18) = criteria[0] else {
            Issue.record("Expected ageAtLeast(18), got \(criteria[0])")
            return
        }

        guard case .any(let anyCriteria) = criteria[1] else {
            Issue.record("Expected any, got \(criteria[1])")
            return
        }
        #expect(anyCriteria.count == 2)

        guard case .not(let inner) = criteria[2], case .ageAtLeast(65) = inner else {
            Issue.record("Expected not(ageAtLeast(65)), got \(criteria[2])")
            return
        }

        guard case .speaksLanguage(let lang) = criteria[3] else {
            Issue.record("Expected speaksLanguage, got \(criteria[3])")
            return
        }
        #expect(lang.minimalIdentifier == "en")
    }

    @Test
    func roundTripEmptyAll() throws {
        let original: StudyDefinition.ParticipationCriterion = .all([])
        let schema = try Components.Schemas.ParticipationCriterion(original)
        let roundTripped = StudyDefinition.ParticipationCriterion(schema)

        guard case .all(let criteria) = roundTripped else {
            Issue.record("Expected all, got \(roundTripped)")
            return
        }
        #expect(criteria.isEmpty)
    }
}
