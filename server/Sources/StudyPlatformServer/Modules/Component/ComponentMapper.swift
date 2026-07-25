//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziHealthKit
import SpeziHealthKitBulkExport
import SpeziStudyDefinition
import StudyPlatformAPIServer


extension Components.Schemas.Component._TypePayload {
    init(_ model: ComponentType) {
        switch model {
        case .informational: self = .informational
        case .questionnaire: self = .questionnaire
        case .healthDataCollection: self = .healthDataCollection
        }
    }
}

extension Components.Schemas.Component {
    init(_ model: Component) throws {
        self.init(
            id: try model.requireId().uuidString,
            _type: .init(model.type),
            name: model.name
        )
    }
}


extension Components.Schemas.InformationalComponentResponse {
    init(_ model: Component) throws {
        guard case .informational(let content) = model.data else {
            throw ServerError.internalServerError("Expected informational component data")
        }
        self.init(
            id: try model.requireId().uuidString,
            name: model.name,
            data: content
        )
    }
}


extension Components.Schemas.QuestionnaireComponentResponse {
    init(_ model: Component) throws {
        guard case .questionnaire(let content) = model.data else {
            throw ServerError.internalServerError("Expected questionnaire component data")
        }
        self.init(
            id: try model.requireId().uuidString,
            name: model.name,
            data: content
        )
    }
}


extension Components.Schemas.HealthDataComponentResponse {
    init(_ model: Component) throws {
        guard case .healthDataCollection(let content) = model.data else {
            throw ServerError.internalServerError("Expected health data component data")
        }
        self.init(
            id: try model.requireId().uuidString,
            name: model.name,
            data: .init(content)
        )
    }
}


// MARK: - Model to Schema

extension Components.Schemas.HealthDataComponentData {
    init(_ model: StudyDefinition.HealthDataCollectionComponent) {
        let historicalDataCollection: HistoricalDataCollectionPayload?
        switch model.historicalDataCollection {
        case .disabled:
            historicalDataCollection = .init(enabled: false)
        case .enabled(let startDate):
            historicalDataCollection = .init(
                enabled: true,
                startDate: .init(startDate)
            )
        }

        self.init(
            sampleTypes: model.sampleTypes.map { SampleTypeProxy($0) },
            historicalDataCollection: historicalDataCollection
        )
    }
}

extension Components.Schemas.ExportSessionStartDate {
    init(_ model: ExportSessionStartDate) {
        switch model {
        case .oldestSample:
            self = .oldestSample(.init(_type: .oldestSample))
        case .last(let components):
            self = .last(.init(_type: .last, components: .init(components)))
        case .absolute(let date):
            self = .absolute(.init(_type: .absolute, date: date))
        }
    }
}

// MARK: - Schema to Model

extension StudyDefinition.HealthDataCollectionComponent {
    init(_ schema: Components.Schemas.HealthDataComponentData) {
        let historicalDataCollection: HistoricalDataCollection
        if let historical = schema.historicalDataCollection,
           historical.enabled == true {
            if let startDate = historical.startDate {
                historicalDataCollection = .enabled(ExportSessionStartDate(startDate))
            } else {
                historicalDataCollection = .enabled(.oldestSample)
            }
        } else {
            historicalDataCollection = .disabled
        }

        self.init(
            id: UUID(),
            sampleTypes: SampleTypesCollection(schema.sampleTypes),
            optionalSampleTypes: [],
            historicalDataCollection: historicalDataCollection
        )
    }
}

extension ExportSessionStartDate {
    init(_ schema: Components.Schemas.ExportSessionStartDate) {
        switch schema {
        case .oldestSample:
            self = .oldestSample
        case .last(let relative):
            self = .last(Foundation.DateComponents(relative.components))
        case .absolute(let absolute):
            self = .absolute(absolute.date)
        }
    }
}
