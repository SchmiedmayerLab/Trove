//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPITypes


struct EventTargetIntentTests {
    @Test
    func consentAndOutputOrderDoNotChangeTheCommitment() throws {
        let first = EventTargetIntent.Target(consentID: UUID(), outputFullURLs: ["urn:a", "urn:b"])
        let second = EventTargetIntent.Target(consentID: UUID(), outputFullURLs: ["urn:c"])
        let original = try EventTargetIntent(targets: [first, second])
        let reordered = try EventTargetIntent(targets: [second, .init(consentID: first.consentID, outputFullURLs: ["urn:b", "urn:a"])])
        #expect(original.serialized == reordered.serialized)
        #expect(original.sha256 == reordered.sha256)
        let decoded = try JSONDecoder().decode([EventTargetIntent.Target].self, from: Data(original.serialized.utf8))
        #expect(decoded == original.targets)
    }

    @Test(arguments: [[], [""], ["urn:a", "urn:a"], ["urn:é"], ["urn:a\n"], [String(repeating: "a", count: 513)]])
    func invalidOutputSetsAreRejected(outputs: [String]) throws {
        #expect(throws: EventTargetIntent.ValidationError.invalidTargets) {
            try EventTargetIntent(targets: [.init(consentID: UUID(), outputFullURLs: outputs)])
        }
    }

    @Test(arguments: [17])
    func consentCountIsBounded(count: Int) throws {
        let targets = (0..<count).map { _ in EventTargetIntent.Target(consentID: UUID(), outputFullURLs: ["urn:a"]) }
        #expect(throws: EventTargetIntent.ValidationError.invalidTargets) { try EventTargetIntent(targets: targets) }
    }

    @Test
    func restrictiveIntentHasAnExactEmptyCommitment() throws {
        let intent = try EventTargetIntent(targets: [])
        #expect(intent.targets.isEmpty)
        #expect(intent.serialized == "[]")
        #expect(intent.sha256 == "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945")
    }

    @Test
    func repeatedConsentCannotSplitIntoMultipleTargets() throws {
        let consentID = UUID()
        #expect(throws: EventTargetIntent.ValidationError.invalidTargets) {
            try EventTargetIntent(targets: [
                .init(consentID: consentID, outputFullURLs: ["urn:a"]), .init(consentID: consentID, outputFullURLs: ["urn:b"])
            ])
        }
    }

    @Test
    func outputCountAndCombinedEncodedSizeAreIndependentlyBounded() throws {
        let outputs = (0..<513).map { "urn:output:\($0)" }
        #expect(throws: EventTargetIntent.ValidationError.invalidTargets) {
            try EventTargetIntent(targets: [.init(consentID: UUID(), outputFullURLs: outputs)])
        }
        let boundedOutputs = (0..<512).map { "urn:output:\($0):" + String(repeating: "a", count: 490) }
        let target = EventTargetIntent.Target(consentID: UUID(), outputFullURLs: boundedOutputs)
        #expect(try EventTargetIntent(targets: [target]).serialized.utf8.count <= EventTargetIntent.maximumBytes)
        let targets = (0..<3).map { _ in EventTargetIntent.Target(consentID: UUID(), outputFullURLs: boundedOutputs) }
        #expect(throws: EventTargetIntent.ValidationError.oversizedIntent) { try EventTargetIntent(targets: targets) }
    }
}
