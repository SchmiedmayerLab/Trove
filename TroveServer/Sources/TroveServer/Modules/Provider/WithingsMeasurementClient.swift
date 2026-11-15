//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveProviderFHIR
import TroveAPITypes


/// Only facts consumed by this consented conversion can change its retained conversion instant.
private struct WithingsConversionFingerprint: Encodable {
    let date: Int64
    let timeZone: String
    let model: String?
    let deviceToken: String?
    let measures: [WithingsMeasureResponse.Group.Measure]
}


/// Numeric measure groups retain the upstream group ID, date, exact integer scaling and stated device facts.
struct WithingsMeasurementClient: ProviderAcquisitionClient {
    let provider = ConnectedProvider.withings
    let transport: ProviderHTTPTransport
    let limits: EventSubmissionLimits.Configuration

    var qualifiedSourceTokens: Set<String> {
        let sources = ProviderCapabilities.sources(for: .withings).filter {
            $0.conversionSupport == .structured && $0.token.hasPrefix("getmeas:")
        }
        return Set(sources.map(\.token))
    }

    private static func device(_ group: WithingsMeasureResponse.Group, scope: ProviderConversionContext.Scope) throws -> RecordingDevice {
        var device = RecordingDevice()
        device.model = group.model
        if let token = group.deviceid ?? group.hashedDeviceID {
            guard case .account(let account) = scope else { throw ProviderFailure.invalidConfiguration }
            device.stableUnitToken = token
            device.tokenScope = account.system.rawValue + "/" + account.value
        }
        return device
    }

    private static func measureTypes(_ token: String) throws -> Set<Int> {
        guard token.hasPrefix("getmeas:") else { throw ProviderFailure.invalidPayload }
        let values = token.dropFirst("getmeas:".count).split(separator: "+")
        let types = values.compactMap { Int($0) }
        guard !types.isEmpty, types.count == values.count else { throw ProviderFailure.invalidPayload }
        return Set(types)
    }

    func fetch(_ request: ProviderAcquisitionRequest, credentials: ProviderCredentials) async throws -> ProviderAcquisitionPage {
        guard request.registration.provider == .withings, qualifiedSourceTokens.contains(request.sourceToken),
              let capability = ProviderCapabilities.sources(for: .withings).first(where: { $0.token == request.sourceToken }),
              request.demands.contains(where: { demand in
                  capability.outputProfiles.contains { $0.value?.url.absoluteString == demand.profile }
              }) else {
            throw ProviderFailure.scopeLost
        }
        let types = try Self.measureTypes(request.sourceToken)
        var fields = [
            "action": "getmeas", "category": "1", "meastypes": types.sorted().map(String.init).joined(separator: ","),
            "startdate": String(Int64(request.window.lowerBound.timeIntervalSince1970.rounded(.down))),
            "enddate": String(Int64(request.window.upperBound.timeIntervalSince1970.rounded(.up)))
        ]
        if let cursor = request.cursor {
            guard let offset = Int64(cursor), offset >= 0 else { throw ProviderFailure.invalidPayload }
            fields["offset"] = cursor
        }
        let bytes = try await transport.send(.withingsMeasures, ProviderHTTPTransport.form(fields), credentials.accessToken, limits.bundleBytes)
        let response: WithingsMeasureResponse
        do { response = try JSONDecoder().decode(WithingsMeasureResponse.self, from: bytes) } catch { throw ProviderFailure.invalidPayload }
        return try await convert(response, request: request, types: types)
    }

    private func convert(
        _ response: WithingsMeasureResponse, request: ProviderAcquisitionRequest, types: Set<Int>
    ) async throws -> ProviderAcquisitionPage {
        guard response.status == 0, let body = response.body, let zone = TimeZone(identifier: body.timezone),
              body.measuregrps.count <= 256, [0, 1].contains(body.more) else { throw ProviderFailure.invalidPayload }
        var records: [Data] = []
        var excluded = 0
        var totalBytes = 0
        var seen: Set<Int64> = []
        for group in body.measuregrps {
            guard seen.insert(group.grpid).inserted else { throw ProviderFailure.invalidPayload }
            guard let record = try await record(group, zoneName: body.timezone, zone: zone, request: request, types: types) else {
                excluded += 1
                continue
            }
            guard record.count <= limits.recordBytes, record.count <= limits.bundleBytes - totalBytes else {
                throw ProviderFailure.capacityExceeded
            }
            totalBytes += record.count
            records.append(record)
        }
        let next: String?
        if body.more == 1 {
            guard let offset = body.offset, offset >= 0, String(offset) != request.cursor else { throw ProviderFailure.invalidPayload }
            next = String(offset)
        } else { next = nil }
        return .init(records: records, nextCursor: next, complete: body.more == 0, excludedRows: excluded)
    }

    /// Converts one measure group. Returns nil for a group outside the consented demand; a malformed group fails the page.
    private func record(
        _ group: WithingsMeasureResponse.Group, zoneName: String, zone: TimeZone, request: ProviderAcquisitionRequest, types: Set<Int>
    ) async throws -> Data? {
        guard group.grpid > 0, group.measures.count <= 256,
              Set(group.measures.map(\.type)).count == group.measures.count else { throw ProviderFailure.invalidPayload }
        let date = Date(timeIntervalSince1970: TimeInterval(group.date))
        guard CollectionMeasurementWindow.valid(date) else { throw ProviderFailure.invalidPayload }
        guard [0, 1, 2, 4, 5, 7, 8, 15].contains(group.attrib) else { throw ProviderFailure.invalidPayload }
        guard group.category == 1, group.attrib != 1, request.demands.contains(where: { date >= $0.start && date < $0.end }) else {
            return nil
        }
        let device = try Self.device(group, scope: request.scope)
        let measures = group.measures.filter { types.contains($0.type) }
        guard measures.count == types.count else { throw ProviderFailure.invalidPayload }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let fingerprintBytes = try encoder.encode(WithingsConversionFingerprint(
            date: group.date,
            timeZone: zoneName,
            model: group.model,
            deviceToken: device.stableUnitToken,
            measures: measures.sorted { $0.type < $1.type }
        ))
        let instant = try await request.conversionInstant(String(group.grpid), fingerprintBytes)
        let results = try WithingsFHIR.convert(.init(
            id: String(group.grpid),
            date: date,
            measures: measures.map { .init(type: $0.type, value: $0.value, unit: $0.unit) }
        ), context: .init(
            producer: request.producer,
            scope: request.scope,
            instant: instant,
            sourceTimeZone: zone,
            recordingDevice: group.model != nil || device.stableUnitToken != nil ? device : nil
        ))
        guard results.count == 1, let result = results.first, result.sourceToken == request.sourceToken,
              result.omissions.isEmpty, let record = result.record else { throw ProviderFailure.invalidPayload }
        return record.json
    }
}
