// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation


/// The retained publication supplies the definition identities for every task issued under that revision.
enum StudyTaskDefinitions {
    struct Pins: Equatable {
        let activity: String
        let plan: String
    }

    static let filename = "task-definitions.json"
    static let profiles = "https://grovealliance.org/fhir/study/StructureDefinition/"
    static let invalid = ServerError.conflict("Invalid published task definitions")

    static func pinnedCanonical(_ value: String) -> Bool {
        let parts = value.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, !value.contains("#"), !value.contains(where: \.isWhitespace),
              let url = URLComponents(string: String(parts[0])), ["http", "https"].contains(url.scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    static func validBase(_ base: String) -> Bool {
        guard let url = URLComponents(string: base), url.scheme == "https" || url.scheme == "http", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !base.contains("|"), !base.contains("#"), !base.contains(where: \.isWhitespace) else { return false }
        return true
    }

    static func build(study: UUID, revision: Int, base: String, instruments: [UUID: String]) throws -> Data {
        guard revision > 0, !instruments.isEmpty, validBase(base) else { throw invalid }
        let studyID = study.uuidString.lowercased()
        let prefix = (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/studies/" + studyID
        let version = String(revision)
        var entries: [[String: Any]] = []
        var actions: [[String: String]] = []
        for component in instruments.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let questionnaire = instruments[component], pinnedCanonical(questionnaire) else { throw invalid }
            let id = component.uuidString.lowercased()
            let address = prefix + "/ActivityDefinition/" + id
            let activity: [String: Any] = [
                "resourceType": "ActivityDefinition", "id": id, "url": address, "version": version,
                "meta": ["profile": [profiles + "grove-study-questionnaire-component"]],
                "status": "active", "kind": "Task", "intent": "order",
                "code": ["coding": [["system": "http://hl7.org/fhir/uv/sdc/CodeSystem/temp", "code": "complete-questionnaire"]]],
                "relatedArtifact": [["type": "depends-on", "resource": questionnaire]]
            ]
            entries.append(["fullUrl": address, "resource": activity])
            actions.append(["definitionCanonical": address + "|" + version])
        }
        let address = prefix + "/PlanDefinition/" + studyID
        let plan: [String: Any] = [
            "resourceType": "PlanDefinition", "id": studyID, "url": address, "version": version, "status": "active",
            "meta": ["profile": [profiles + "grove-study-protocol"]], "action": actions
        ]
        entries.append(["fullUrl": address, "resource": plan])
        let bundle: [String: Any] = ["resourceType": "Bundle", "type": "collection", "entry": entries]
        let graph = try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys, .withoutEscapingSlashes])
        guard graph.count <= FHIRValidationClient.maximumBytes else { throw StudyProjectionJSON.Failure.outputTooLarge }
        return graph
    }

    static func resolve(_ bytes: Data, study: UUID, revision: Int, component: UUID, questionnaire: String) throws -> Pins {
        let graph = try StudyProjectionJSON.readResult(bytes)
        guard graph["resourceType"]?.string == "Bundle", graph["type"]?.string == "collection",
              let entries = graph["entry"]?.array else { throw invalid }
        let resources = entries.compactMap { $0["resource"] }
        func definition(_ kind: String, id: UUID) throws -> (String, StudyProjectionJSON) {
            let matches = resources.filter { $0["resourceType"]?.string == kind && $0["id"]?.string == id.uuidString.lowercased() }
            guard matches.count == 1, let value = matches.first, let url = value["url"]?.string,
                  value["version"]?.string == String(revision), value["status"]?.string == "active",
                  resources.filter({ $0["url"]?.string == url && $0["version"]?.string == String(revision) }).count == 1,
                  pinnedCanonical(url + "|" + String(revision)) else { throw invalid }
            return (url + "|" + String(revision), value)
        }
        let (activity, resource) = try definition("ActivityDefinition", id: component)
        let (protocolPin, plan) = try definition("PlanDefinition", id: study)
        let dependencies = resource["relatedArtifact"]?.array?.filter { $0["type"]?.string == "depends-on" }
        let coding = resource["code"]?["coding"]?.array
        let hasCompletionCode = coding?.contains {
            $0["system"]?.string == "http://hl7.org/fhir/uv/sdc/CodeSystem/temp" && $0["code"]?.string == "complete-questionnaire"
        }
        guard resource["kind"]?.string == "Task", resource["intent"]?.string == "order",
              resource["meta"]?["profile"]?.array?.contains(where: { $0.string == profiles + "grove-study-questionnaire-component" }) == true,
              plan["meta"]?["profile"]?.array?.contains(where: { $0.string == profiles + "grove-study-protocol" }) == true,
              hasCompletionCode == true,
              dependencies?.count == 1, dependencies?.first?["resource"]?.string == questionnaire,
              plan["action"]?.array?.contains(where: { $0["definitionCanonical"]?.string == activity }) == true else { throw invalid }
        return .init(activity: activity, plan: protocolPin)
    }
}
