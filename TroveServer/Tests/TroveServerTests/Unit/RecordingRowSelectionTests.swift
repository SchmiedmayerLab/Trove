//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import Testing
@testable import TroveServer


struct RecordingRowSelectionTests {
    @Test
    func distinctStudyWindowsSelectOnlyTheirRowsAndRetainLexemes() async throws {
        let header = "timestamp,value,confidence,device\n"
        let first = "10,72.00000000000001,3,Watch\n"
        let middle = "20,73,3,Watch\n"
        let last = "30,74,3,Watch\n"
        let source = try await file(header + first + middle + last)
        let selection = try RecordingRowSelection(windows: [window(10, 11), window(30, 31)])
        let result = try await selection.filter(source, format: .heartRateSamples)
        #expect(result.isDerived && result.sourceRows == 3 && result.selectedRows == 2)
        #expect(try bytes(result.file) == Data((header + first + last).utf8))
        #expect(try bytes(source) == Data((header + first + middle + last).utf8))
    }

    @Test
    func completeUnionReturnsUnchangedBytesAndHash() async throws {
        let original = "timestamp,value,confidence,device\n10,72,3,\"Watch\"\n20,73,3,Watch\n"
        let source = try await file(original)
        let selection = try RecordingRowSelection(windows: [window(10, 15), window(15, 21), window(12, 17)])
        let result = try await selection.filter(source, format: .heartRateSamples)
        #expect(!result.isDerived && result.selectedRows == 2)
        #expect(try Data(Insecure.SHA1.hash(data: bytes(result.file))) == Data(Insecure.SHA1.hash(data: bytes(source))))
        #expect(try bytes(result.file) == Data(original.utf8))
    }

    @Test
    func halfOpenPointsAndWholeNativeIntervalsHaveDifferentBoundaries() throws {
        let selection = try RecordingRowSelection(windows: [window(10, 20)])
        let points = try RecordingCSVReader(Data("timestamp,value,confidence,device\n10,72,3,Watch\n20,72,3,Watch\n".utf8), format: .heartRateSamples)
        #expect(try selection.includes(points.rows[0], format: .heartRateSamples))
        #expect(try !selection.includes(points.rows[1], format: .heartRateSamples))
        let intervals = try RecordingCSVReader(Data((
            "start,end,steps,distance,floorsUp,floorsDown,currentPace,currentCadence,avgActivePace,device\n"
                + "9,11,5,,,,,,,Watch\n19,21,5,,,,,,,Watch\n20,21,5,,,,,,,Watch\n"
        ).utf8), format: .pedometerSamples)
        #expect(try selection.includes(intervals.rows[0], format: .pedometerSamples))
        #expect(try selection.includes(intervals.rows[1], format: .pedometerSamples))
        #expect(try !selection.includes(intervals.rows[2], format: .pedometerSamples))
    }

    @Test
    func emptySelectionDisclosesNoRows() async throws {
        let selection = RecordingRowSelection(windows: [])
        let source = try await file("timestamp,value,confidence,device\n10,72,3,Watch\n")
        let result = try await selection.filter(source, format: .heartRateSamples)
        #expect(result.isDerived && result.selectedRows == 0)
        #expect(try bytes(result.file) == Data("timestamp,value,confidence,device\n".utf8))
    }

    private func window(_ start: TimeInterval, _ end: TimeInterval) throws -> RecordingRowSelection.Window {
        try .init(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    private func file(_ value: String) async throws -> RecordingFile {
        let data = Data(value.utf8)
        return try await RecordingFile.stage(chunks: AsyncStream<Data> { $0.yield(data); $0.finish() }, maximumByteCount: Int64(data.count))
    }

    private func bytes(_ file: RecordingFile) throws -> Data {
        var reader = file.makeChunkReader(), result = Data()
        while let chunk = try reader.readNextChunk() { result.append(chunk) }
        return result
    }
}
