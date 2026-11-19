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
import SQLKit


/// The one disclosure rule for facts that identify a physical device unit. A study receives them for a record only
/// when every one of the study's grants for that record's event comes from a published revision that receives them;
/// otherwise they are withheld from its derived views and from recordings whose format can carry them.
///
/// Recording and host Devices keep only facts about a kind of device: status, type, manufacturer, model number,
/// versions, parent, patient, the UDI device identifier, issuer and jurisdiction, and model, manufacturer and UDI label
/// names. Everything else, including serial and lot numbers, dates, UDI production data, names a person gave a device
/// and every identifier, is withheld. Application Devices keep their names and identifiers unless HealthKit assigned
/// their bundle identifier to one device (`com.apple.health.`). The rule also withholds the HealthKit source name and
/// bundle identifier of such a device, readable sync identifiers scoped to it, and the HealthKit metadata keys that
/// repeat a withheld Device fact. Producer free text is not filtered.
///
/// The rule reads only derived views. Retained bytes, record identity, deduplication, receipts and retractions never
/// depend on it.
enum StudyDeviceUnitDisclosure {
    /// One of a study's grants for an event, with the published revision it was issued under.
    struct Grant: Sendable, Equatable {
        let eventID: UUID
        let publicationID: UUID
        let revision: Int
    }

    /// Names the withholding in the derivation Provenance, so absent facts are not read as unstated ones.
    static let withheldPolicy = "urn:trove:device-unit-identifiers-withheld"

    private static let deviceBundlePrefix = "com.apple.health."
    private static let sourceRevision = Canonicals.root + "/healthkit/StructureDefinition/healthkit-source-revision"
    private static let roleSystem = Canonicals.root + "/mobile/CodeSystem/grove-identifier-role"
    private static let deviceIdentifierTypeSystem = Canonicals.root + "/mobile/CodeSystem/grove-device-identifier-type"
    private static let applicationProfiles = [Profile.groveApplicationDevice, Profile.healthkitApplicationDevice]
        .compactMap { $0.value?.url.absoluteString }
    private static let metadataKeys: Set<String> = ["HKDeviceSerialNumber", "HKDeviceName", "HKUDIProductionIdentifier"]
    private static let deviceMembers: Set<String> = [
        "resourceType", "meta", "status", "type", "manufacturer", "modelNumber", "version", "parent", "patient", "udiCarrier", "deviceName"
    ]
    private static let carrierMembers: Set<String> = ["deviceIdentifier", "issuer", "jurisdiction"]
    private static let kindNames: Set<String> = ["model-name", "manufacturer-name", "udi-label-name"]
    private static var unavailable: ServerError { .internalServerError("Study data is unavailable") }

    /// The events among `eventIDs` for which this study receives unit facts. Every one of the study's grants for an
    /// event counts, whichever page or grant identifier led to it. Loads the study's publications once.
    static func receivingEvents(_ eventIDs: Set<UUID>, studyID: UUID, on database: any Database) async throws -> Set<UUID> {
        guard !eventIDs.isEmpty else {
            return []
        }
        guard database.inTransaction else { throw AuditError.transactionRequired }
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let rows = try await sql.raw("""
            SELECT DISTINCT n.event_id, g.publication_id, g.revision FROM study_data_grants g
            JOIN clinical_event_nodes n ON n.id = g.node_id
            WHERE g.study_id = \(bind: studyID) AND n.event_id IN (\(binds: Array(eventIDs)))
            """)
            .all()
        let grants = try rows.map {
            try Grant(
                eventID: $0.decode(column: "event_id", as: UUID.self),
                publicationID: $0.decode(column: "publication_id", as: UUID.self),
                revision: $0.decode(column: "revision", as: Int.self)
            )
        }
        // A grant naming a publication that is not loaded fails through the guard in `receivingEvents(_:policies:studyID:)`.
        let publications = try await PublishedStudy.query(on: database)
            .filter(\.$id ~~ Array(Set(grants.map(\.publicationID))))
            .field(\.$id)
            .field(\.$collectionPolicy)
            .all()
        let policies = try Dictionary(uniqueKeysWithValues: publications.map { try ($0.requireID(), $0.collectionPolicy) })
        return try receivingEvents(grants, policies: policies, studyID: studyID)
    }

    /// An event receives unit facts only when it has grants and every one of them comes from a revision that receives
    /// them. A grant whose publication is not this study's, or whose revision differs, is corrupt evidence and fails;
    /// so does an invalid or unknown policy.
    static func receivingEvents(_ grants: [Grant], policies: [UUID: PublishedCollectionPolicy], studyID: UUID) throws -> Set<UUID> {
        var withheld: Set<UUID> = []
        for grant in grants {
            guard let policy = policies[grant.publicationID], policy.studyID == studyID, policy.revision == grant.revision else {
                throw unavailable
            }
            if try !policy.validatedDeviceUnitDisclosure(studyID: studyID, revision: grant.revision) {
                withheld.insert(grant.eventID)
            }
        }
        return Set(grants.map(\.eventID)).subtracting(withheld)
    }

    /// Whether a recording's original bytes can be released unchanged to a study that does not receive unit facts.
    /// The `device` and `originDevice` columns of tabular formats are strings the producer states (Grove writes the
    /// product type) and are not checked at admission; the photoplethysmogram format has no device column.
    /// Clinical-record documents are the care record, collected under their own consented requirement.
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

    /// Removes unit facts from one projected resource. References are never removed, so the graph stays closed; a
    /// reference to a Device keeps only its address and type, because its display text can name the unit.
    static func withhold(from resource: inout [String: StudyProjectionJSON], isDevice: (String) -> Bool) throws {
        resource = deviceReferences(in: .object(resource), isDevice: isDevice).object ?? resource
        switch resource["resourceType"]?.string {
        case "Device": device(&resource)
        case "Provenance": try provenance(&resource)
        case "Observation":
            try metadata(&resource)
            syncIdentifiers(&resource)
        case "DocumentReference":
            try metadata(&resource)
            syncIdentifiers(&resource)
            try recording(&resource)
        default: break
        }
    }

    private static func device(_ resource: inout [String: StudyProjectionJSON]) {
        let identifiers = resource["identifier"]?.array ?? []
        let profiles = resource["meta"]?["profile"]?.array?.compactMap(\.string) ?? []
        // An application's typed identifier and user-friendly name describe software, unless HealthKit assigned its
        // bundle identifier to one device. Every other member follows the same allowlist as a recording Device.
        let application = profiles.contains(where: applicationProfiles.contains)
            && !identifiers.contains { isDeviceBundle($0["value"]?.string) }
        let names = resource["deviceName"]?.array?.filter { name in
            let type = name["type"]?.string ?? ""
            return kindNames.contains(type) || (application && type == "user-friendly-name")
        } ?? []
        resource = resource.filter { deviceMembers.contains($0.key) }
        resource["deviceName"] = names.isEmpty ? nil : .array(names)
        let typed = application ? identifiers.filter { $0["type"] != nil && !isUnitIdentifier($0) } : []
        resource["identifier"] = typed.isEmpty ? nil : .array(typed)
        let carriers = resource["udiCarrier"]?.array?.compactMap { carrier -> StudyProjectionJSON? in
            let members = carrier.object?.filter { carrierMembers.contains($0.key) } ?? [:]
            return members["deviceIdentifier"] == nil ? nil : .object(members)
        } ?? []
        resource["udiCarrier"] = carriers.isEmpty ? nil : .array(carriers)
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
                let members = revision["extension"]?.array ?? []
                guard members.allSatisfy({ $0["url"]?.string != nil }) else {
                    throw FHIRValidationClient.invalid
                }
                // A device-assigned bundle identifier makes the source a device, and its name the one a person gave it.
                let device = members.contains { $0["url"]?.string == "sourceBundleIdentifier" && isDeviceBundle($0["valueString"]?.string) }
                let facts = members.filter { !device || !["sourceName", "sourceBundleIdentifier"].contains($0["url"]?.string ?? "") }
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

    /// A recording that cannot be released unchanged keeps its title, description, size and hash but loses its content
    /// and its download location, matching the refusal of the download route.
    private static func recording(_ resource: inout [String: StudyProjectionJSON]) throws {
        guard let contents = resource["content"]?.array else {
            return
        }
        resource["content"] = try .array(contents.map { content in
            guard var members = content.object, var attachment = members["attachment"]?.object else {
                throw FHIRValidationClient.invalid
            }
            let format = content["format"]?["system"]?.string == FHIRRecordingProjection.formatSystem
                ? content["format"]?["code"]?.string.flatMap(RegisteredRecordingFormat.init(rawValue:))
                : nil
            guard format.map(releasesUnchanged) != true else {
                return content
            }
            remove(["data", "url"], from: &attachment)
            members["attachment"] = .object(attachment)
            return .object(members)
        })
    }

    /// A readable sync identifier's system ends with the writer's bundle identifier; withhold one scoped to a device.
    private static func syncIdentifiers(_ resource: inout [String: StudyProjectionJSON]) {
        guard let identifiers = resource["identifier"]?.array else {
            return
        }
        let marker = ("/" + FHIRSyncRecordIdentifier.systemPathSegment + "/" + deviceBundlePrefix).lowercased()
        let retained = identifiers.filter { $0["system"]?.string?.lowercased().contains(marker) != true }
        resource["identifier"] = retained.isEmpty ? nil : .array(retained)
    }

    private static func isUnitIdentifier(_ identifier: StudyProjectionJSON) -> Bool {
        let codings = identifier["type"]?["coding"]?.array ?? []
        return isDeviceBundle(identifier["value"]?.string) || codings.contains {
            ($0["system"]?.string == roleSystem && $0["code"]?.string == "recording-device")
                || ($0["system"]?.string == deviceIdentifierTypeSystem && $0["code"]?.string == "device-local-identifier")
        }
    }

    /// HealthKit assigns `com.apple.health.<UUID>` to one iPhone or Apple Watch. Any value with that prefix counts, in any case.
    private static func isDeviceBundle(_ value: String?) -> Bool {
        value?.lowercased().hasPrefix(deviceBundlePrefix) == true
    }

    /// Reduces every reference to a Device to its address and type.
    private static func deviceReferences(in value: StudyProjectionJSON, isDevice: (String) -> Bool) -> StudyProjectionJSON {
        switch value {
        case .scalar: return value
        case .array(let elements): return .array(elements.map { deviceReferences(in: $0, isDevice: isDevice) })
        case .object(let members):
            if let address = members["reference"]?.string, isDevice(address) {
                return .object(members.filter { ["reference", "type"].contains($0.key) })
            }
            return .object(members.mapValues { deviceReferences(in: $0, isDevice: isDevice) })
        }
    }

    /// Removes members together with their primitive extensions (`_name`).
    private static func remove(_ names: [String], from members: inout [String: StudyProjectionJSON]) {
        for name in names {
            members[name] = nil
            members["_" + name] = nil
        }
    }
}
