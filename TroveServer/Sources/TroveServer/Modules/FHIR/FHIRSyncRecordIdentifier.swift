//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4


/// The readable HealthKit sync identifier a producer discloses beside the native record identifier (HealthKit guide,
/// `mapping.md`). Like the native UUID it is informative evidence only: it never names an identity, entry key,
/// duplicate, version, receipt or retraction. Its exact text stays in the retained bytes and is never normalized.
enum FHIRSyncRecordIdentifier {
    /// Grove's generated `HealthKitContract` declares the type coding and the system path segment with package access
    /// only; these mirror it, and a test checks them against Grove's golden records.
    static let typeSystem = "https://grovealliance.org/fhir/healthkit/CodeSystem/healthkit-identifier-type"
    static let typeCode = "healthkit-sync-id"
    static let systemPathSegment = "healthkit-sync-identifier"

    /// Whether any coding of the identifier's type names a readable sync identifier.
    static func isTyped(_ identifier: Identifier) -> Bool {
        identifier.type?.coding?.contains { $0.system?.value?.url.absoluteString == typeSystem && $0.code?.value?.string == typeCode } == true
    }

    /// Validates the sync identifier of an Observation or DocumentReference primary as Grove produces and checks it: its
    /// coding is its only type; it travels on a HealthKit output beside the native UUID, the writer-record identity and
    /// exactly one writer-record version; and its system is exactly the native system, which names an authority and has no
    /// query or fragment, then the path segment and one writing application's bundle identifier.
    static func validated(
        _ identifier: Identifier, native: ValidatedExchangeEvent.Identifier, roles: [RoledIdentifier], extensions: [Extension]
    ) throws -> ValidatedExchangeEvent.Identifier {
        let prefix = native.system + "/" + systemPathSegment + "/"
        guard identifier.type?.coding?.count == 1, identifier.type?.text == nil,
              identifier.use == nil, identifier.period == nil, identifier.assigner == nil, identifier.extension?.isEmpty != false,
              extensions.contains(where: { $0.url == Canonicals.healthKitSourceTypeExtension }),
              roles.contains(where: { $0.role == .writerRecord }),
              extensions.filter({ $0.url == Canonicals.writerRecordVersion }).count == 1,
              namesAuthority(native.system),
              let system = identifier.system?.value?.url.absoluteString, (1...512).contains(system.utf8.count),
              system.hasPrefix(prefix), isWriterSegment(system.dropFirst(prefix.count)) else {
            throw FHIRValidationClient.invalid
        }
        let business = try BusinessIdentifier(identifier)
        return .init(system: business.system.rawValue, value: business.value)
    }

    /// Every element in the graph typed as a sync identifier, wherever it appears. The receiver compares it with the
    /// identifiers it accepted on primaries, so a sync identifier on any other element fails closed.
    static func count(in bytes: Data) throws -> Int {
        func count(_ value: Any) -> Int {
            if let object = value as? [String: Any] {
                let codings = (object["type"] as? [String: Any])?["coding"] as? [[String: Any]] ?? []
                let typed = codings.contains { $0["system"] as? String == typeSystem && $0["code"] as? String == typeCode } ? 1 : 0
                return object.values.reduce(typed) { $0 + count($1) }
            }
            return (value as? [Any])?.reduce(0) { $0 + count($1) } ?? 0
        }
        return count(try JSONSerialization.jsonObject(with: bytes))
    }

    /// Whether a native system can carry readable sync identifiers: it names an authority and has no query or fragment,
    /// so the sync identifier's segments extend its path. Grove refuses to disclose under any other system.
    private static func namesAuthority(_ system: String) -> Bool {
        guard let components = URLComponents(string: system) else {
            return false
        }
        return components.percentEncodedHost != nil && components.percentEncodedQuery == nil && components.percentEncodedFragment == nil
    }

    /// An Apple bundle identifier: nonempty ASCII letters, digits, hyphens and periods.
    private static func isWriterSegment(_ segment: Substring) -> Bool {
        !segment.isEmpty && segment.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x2E
        }
    }
}
