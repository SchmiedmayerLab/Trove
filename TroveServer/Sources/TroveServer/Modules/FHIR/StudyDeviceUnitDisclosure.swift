//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveFHIRContract


/// The one disclosure rule for facts that identify a physical device unit. A study receives them only when the
/// published revision behind every grant of the released data says so; otherwise they are withheld from its derived
/// views and from recordings whose format can carry them.
///
/// Unit facts are a Device's serial number, UDI production identifier and carrier strings, its device local
/// identifier and keyed `recording-device` unit identity, and the name a person gave a recording or host Device;
/// HealthKit source names and per-device source bundle identifiers (`com.apple.health.` followed by a UUID); and the
/// HealthKit metadata keys that repeat a withheld Device fact. Manufacturer, model, product type, versions and the UDI
/// device identifier describe a kind of device and still travel.
///
/// The rule reads only derived views. Retained bytes, record identity, deduplication, receipts and retractions never
/// depend on it, so a producer that already withholds these facts leaves nothing for it to remove.
enum StudyDeviceUnitDisclosure {
    /// Names the withholding in the derivation Provenance, so absent facts are not read as unstated ones.
    static let withheldPolicy = "urn:trove:device-unit-identifiers-withheld"

    private static let roleSystem = Canonicals.root + "/mobile/CodeSystem/grove-identifier-role"
    private static let deviceIdentifierTypeSystem = Canonicals.root + "/mobile/CodeSystem/grove-device-identifier-type"
    private static let productionIdentifier = Canonicals.root + "/mobile/StructureDefinition/grove-udi-production-identifier"
    private static let sourceRevision = Canonicals.root + "/healthkit/StructureDefinition/healthkit-source-revision"
    private static let applicationProfiles = [Profile.groveApplicationDevice, Profile.healthkitApplicationDevice]
        .compactMap { $0.value?.url.absoluteString }
    private static let metadataKeys: Set<String> = ["HKDeviceSerialNumber", "HKDeviceName", "HKUDIProductionIdentifier"]

    /// Whether every grant's exact published revision receives unit facts. An unknown or mismatched policy fails.
    static func receives(_ grants: [StudyDataFence.Grant], studyID: UUID, on database: any Database) async throws -> Bool {
        guard !grants.isEmpty else {
            return false
        }
        for publicationID in Set(grants.map(\.publicationID)) {
            guard let publication = try await PublishedStudy.find(publicationID, on: database), publication.$study.id == studyID,
                  grants.allSatisfy({ $0.publicationID != publicationID || $0.revision == publication.revision }),
                  try publication.collectionPolicy.validatedDeviceUnitDisclosure(studyID: studyID, revision: publication.revision) else {
                return false
            }
        }
        return true
    }

    /// Whether a recording's original bytes can be released unchanged to a study that does not receive unit facts.
    /// Tabular and photoplethysmogram payloads have closed sample grammars whose device column names a product type.
    /// Clinical-record documents are released as issued: their content is the care record, not device context.
    /// Native, provider and FHIR collection payloads are opaque to this rule and can carry unit facts.
    static func releasesUnchanged(_ format: RegisteredRecordingFormat) -> Bool {
        switch format {
        case .ambientLightSamples, .ambientPressureSamples, .beatIntervalSeries, .deviceMotionSamples, .headphoneSettingsSamples,
             .heartRateSamples, .locationTrackSamples, .odometerSamples, .pedometerSamples, .photoplethysmogramSamples,
             .triaxialAccelerationSamples, .triaxialRotationSamples, .wristTemperatureSamples, .clinicalDocument, .fhirResource:
            true
        case .nativeRecording, .providerRecording, .fhirCollectionBundle:
            false
        }
    }

    /// Removes unit facts from one projected resource. References are never removed, so the graph stays closed.
    static func withhold(from resource: inout [String: StudyProjectionJSON]) throws {
        switch resource["resourceType"]?.string {
        case "Device": try device(&resource)
        case "Provenance": try provenance(&resource)
        case "Observation": try metadata(&resource)
        case "DocumentReference":
            try metadata(&resource)
            try recording(&resource)
        default: break
        }
    }

    private static func device(_ resource: inout [String: StudyProjectionJSON]) throws {
        let identifiers = resource["identifier"]?.array ?? []
        let profiles = resource["meta"]?["profile"]?.array?.compactMap(\.string) ?? []
        let namesApplication = profiles.contains { applicationProfiles.contains($0) }
            && !identifiers.contains { isDeviceBundleIdentifier($0["value"]?.string) }
        remove(["serialNumber"], from: &resource)
        let retained = identifiers.filter { !isUnitIdentifier($0) }
        resource["identifier"] = retained.isEmpty ? nil : .array(retained)
        if !namesApplication, let names = resource["deviceName"]?.array {
            let kinds = names.filter { $0["type"]?.string != "user-friendly-name" }
            resource["deviceName"] = kinds.isEmpty ? nil : .array(kinds)
        }
        if let carriers = resource["udiCarrier"]?.array {
            let kept = carriers.compactMap { carrier -> StudyProjectionJSON? in
                guard var members = carrier.object else {
                    return carrier
                }
                remove(["carrierAIDC", "carrierHRF"], from: &members)
                let extensions = members["extension"]?.array?.filter { $0["url"]?.string != productionIdentifier } ?? []
                members["extension"] = extensions.isEmpty ? nil : .array(extensions)
                return members.isEmpty ? nil : .object(members)
            }
            resource["udiCarrier"] = kept.isEmpty ? nil : .array(kept)
        }
    }

    private static func provenance(_ resource: inout [String: StudyProjectionJSON]) throws {
        guard let entities = resource["entity"]?.array else {
            return
        }
        resource["entity"] = try .array(entities.map { entity in
            guard var members = entity.object, let extensions = members["extension"]?.array else {
                return entity
            }
            let kept = try extensions.compactMap { item -> StudyProjectionJSON? in
                guard item["url"]?.string == sourceRevision, var revision = item.object else {
                    return item
                }
                let facts = try (revision["extension"]?.array ?? []).filter { fact in
                    switch fact["url"]?.string {
                    case "sourceName": return false
                    case "sourceBundleIdentifier": return !isDeviceBundleIdentifier(fact["valueString"]?.string)
                    case .some: return true
                    case .none: throw FHIRValidationClient.invalid
                    }
                }
                guard !facts.isEmpty else {
                    return nil
                }
                revision["extension"] = .array(facts)
                return .object(revision)
            }
            members["extension"] = kept.isEmpty ? nil : .array(kept)
            return .object(members)
        })
    }

    private static func metadata(_ resource: inout [String: StudyProjectionJSON]) throws {
        guard let extensions = resource["extension"]?.array else {
            return
        }
        let kept = try extensions.compactMap { item -> StudyProjectionJSON? in
            guard item["url"]?.string == FHIRHealthKitMetadataBoundary.url, var container = item.object else {
                return item
            }
            let entries = try (container["extension"]?.array ?? []).filter { entry in
                let keys = entry["extension"]?.array?.filter { $0["url"]?.string == "key" }.compactMap { $0["valueString"]?.string }
                guard let keys, keys.count == 1, let key = keys.first else { throw FHIRValidationClient.invalid }
                return !metadataKeys.contains(key)
            }
            guard !entries.isEmpty else {
                return nil
            }
            container["extension"] = .array(entries)
            return .object(container)
        }
        resource["extension"] = kept.isEmpty ? nil : .array(kept)
    }

    /// A recording that cannot be released unchanged keeps its description, size and hash but loses its content
    /// and its download location, matching the refusal of the download route.
    private static func recording(_ resource: inout [String: StudyProjectionJSON]) throws {
        guard let contents = resource["content"]?.array else {
            return
        }
        resource["content"] = try .array(contents.map { content in
            guard var members = content.object, var attachment = members["attachment"]?.object else {
                throw FHIRValidationClient.invalid
            }
            let format = content["format"]?["code"]?.string.flatMap(RegisteredRecordingFormat.init(rawValue:))
            guard format.map(releasesUnchanged) != true else {
                return content
            }
            remove(["data", "url"], from: &attachment)
            members["attachment"] = .object(attachment)
            return .object(members)
        })
    }

    private static func isUnitIdentifier(_ identifier: StudyProjectionJSON) -> Bool {
        let codings = identifier["type"]?["coding"]?.array ?? []
        return isDeviceBundleIdentifier(identifier["value"]?.string) || codings.contains {
            ($0["system"]?.string == roleSystem && $0["code"]?.string == "recording-device")
                || ($0["system"]?.string == deviceIdentifierTypeSystem && $0["code"]?.string == "device-local-identifier")
        }
    }

    /// HealthKit assigns `com.apple.health.<UUID>` to one iPhone or Apple Watch. Any value with that prefix is withheld.
    private static func isDeviceBundleIdentifier(_ value: String?) -> Bool {
        value?.hasPrefix("com.apple.health.") == true
    }

    /// Removes members together with their primitive extensions (`_name`).
    private static func remove(_ names: [String], from members: inout [String: StudyProjectionJSON]) {
        for name in names {
            members[name] = nil
            members["_" + name] = nil
        }
    }
}
