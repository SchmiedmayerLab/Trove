//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

struct WithingsMeasureResponse: Decodable {
    struct Body: Decodable {
        let timezone: String
        let measuregrps: [Group]
        let more: Int
        let offset: Int64?
    }

    struct Group: Codable {
        enum CodingKeys: String, CodingKey {
            case grpid, attrib, date, category, deviceid, model, measures
            case hashedDeviceID = "hash_deviceid"
        }

        struct Measure: Codable {
            let type: Int
            let value: Int64
            let unit: Int
        }
        let grpid: Int64
        let attrib: Int
        let date: Int64
        let category: Int
        let deviceid: String?
        let hashedDeviceID: String?
        let model: String?
        let measures: [Measure]
    }

    let status: Int
    let body: Body?
}
