// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import ObjectiveC
import Testing
@testable import TroveAPIClient
@testable import TroveHealthKit


struct FoodAcquisitionTests {
    private typealias Fixture = HeartRatePlannerFixture

    private static var application: ApplicationDevice {
        get throws { try ApplicationDevice(name: "Trove Test", bundleIdentifier: "org.trove.test", version: "1") }
    }

    private static func plan(_ stream: HealthKitQueryDefinition.Stream) -> Components.Schemas.ParticipantCollectionPlan {
        var plan = Fixture.plan(start: 100, end: 150)
        plan.windows[0].requirements[0].profile = stream.profile.rawValue
        plan.windows[0].requirements[0].sourceTypeIdentifier = stream.sourceTypeIdentifier
        return plan
    }

    private static func nutrient(_ type: HKQuantityType) -> HKQuantitySample {
        HKQuantitySample(type: type, quantity: HKQuantity(unit: .gram(), doubleValue: 12), start: Fixture.date(110), end: Fixture.date(110))
    }

    /// Stored samples carry the source revision that keys their retained conversion time; an unsaved sample has none.
    /// HealthKit only groups unsaved samples, so mark them as stored after the correlation exists.
    /// Verify the private storage before using KVC so SDK changes fail the test explicitly.
    private static func markAsStored(_ samples: [HKSample]) throws {
        let source = try #require(class_createInstance(HKSource.self, 0) as? HKSource)
        for key in ["name", "bundleIdentifier"] {
            try #require(class_getInstanceVariable(HKSource.self, "_\(key)") != nil, "Stored sample fixture needs updated SDK storage")
        }
        source.setValue("Food Writer", forKey: "name")
        source.setValue("org.trove.test.writer", forKey: "bundleIdentifier")
        let revision = HKSourceRevision(
            source: source, version: "1", productType: nil, operatingSystemVersion: .init(majorVersion: 27, minorVersion: 2, patchVersion: 0)
        )
        try #require(class_getInstanceVariable(HKSample.self, "_sourceRevision") != nil, "Stored sample fixture needs updated SDK storage")
        for sample in samples {
            sample.setValue(revision, forKey: "sourceRevision")
            try #require(sample.sourceRevision == revision && source.bundleIdentifier == "org.trove.test.writer")
        }
    }

    private static func collectNutrient(
        _ sample: HKQuantitySample, using acquisition: HealthKitAcquisition, enabled: Bool
    ) async throws -> UUID? {
        guard enabled else {
            return nil
        }
        let page = try await acquisition.collect(
            localID: DeliveryFixture.epoch, application: try application, host: .init(operatingSystemVersion: "27.2")
        ) { _, _ in
            .init(added: [sample], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)))
        }
        return try #require(page.eventIDs.first)
    }

    @Test(arguments: [false, true])
    func groupingDoesNotGrantNutrientsAndIndependentlySelectedMembersDeduplicate(includeNutrient: Bool) async throws {
        let foodStream = try HealthKitQueryDefinition.Stream(.food)
        let nutrientType = HKQuantityType(.dietaryProtein)
        let nutrientStream = try #require(HealthKitQueryDefinition.Stream(rawValue: nutrientType.identifier))
        let definition = try HealthKitQueryDefinition(stream: nutrientStream, kind: .live, start: Fixture.liveStart)
        try await DeliveryFixture.withJournal(query: definition.encoded()) { journal, _ in
            let parentPlan = Self.plan(foodStream), memberPlan = Self.plan(nutrientStream)
            let state = try await Fixture.retain(includeNutrient ? [parentPlan, memberPlan] : [parentPlan], in: journal)
            let protein = Self.nutrient(nutrientType), fiber = Self.nutrient(HKQuantityType(.dietaryFiber))
            let food = HKCorrelation(
                type: HKCorrelationType(.food), start: Fixture.date(90), end: Fixture.date(160), objects: [protein, fiber]
            )
            try Self.markAsStored([protein, fiber, food])
            let acquisition = try HealthKitAcquisition(journal: journal, scope: DeliveryFixture.scope) {}
            let standalone = try await Self.collectNutrient(protein, using: acquisition, enabled: includeNutrient)
            let foodQueryID = UUID()
            try await journal.createQuery(
                for: DeliveryFixture.sourceID,
                queryID: foodQueryID,
                definition: HealthKitQueryDefinition(stream: foodStream, kind: .live, start: Fixture.liveStart).encoded()
            )
            let page = try await acquisition.collect(
                localID: DeliveryFixture.epoch,
                application: try Self.application,
                host: .init(operatingSystemVersion: "27.2"),
                selection: .init(queryID: foodQueryID, state: state)
            ) { _, _ in
                .init(added: [food], deletedIDs: [], nextAnchor: QueryAnchor(HKQueryAnchor(fromValue: 1)))
            }
            #expect(page.eventIDs.count == (includeNutrient ? 2 : 1))
            if let standalone { #expect(page.eventIDs.contains(standalone)) }
            let parentID = try #require(page.eventIDs.first)
            let parent = try #require(try await journal.prepareAttempt(parentID))
            let graph = try ExchangeGraph(validating: parent.bytes, kind: .active)
            let observation = try #require(graph.bundle.entry?.compactMap { entry in
                if case .observation(let value)? = entry.resource { value } else { nil }
            }.first)
            #expect(observation.hasMember?.count == 2 && observation.value == nil)
            #expect(parent.commitment.targetIntent.targets.map(\.consentID) == [try #require(UUID(uuidString: parentPlan.windows[0].consentId))])
            let checkpoint = try await journal.checkpoint(for: DeliveryFixture.sourceID, queryID: foodQueryID)
            #expect(try await journal.previouslyConvertedHealthKitRecords([fiber.uuid], from: checkpoint).isEmpty)
        }
    }
}

#endif
